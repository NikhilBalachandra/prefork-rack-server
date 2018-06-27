require 'socket'
require 'webrick'  # For parsing HTTP
require 'rack'

class MyHttpServer
  BasicSocket.do_not_reverse_lookup = true
  LISTENING_QUEUE_SIZE = 10

  def initialize(app, host, port, workers)
    @app = app
    @host = host
    @port = port
    @workers = workers
    @pids = []
    @listening_socket = nil
  end

  def self.response_to_s(response)
    r = []
    status = response.status
    r << "HTTP/1.1 #{status} #{Rack::Utils::HTTP_STATUS_CODES[status]}\r\n"
    response.headers.each do |k, v|
      r << "#{k}: #{v}\r\n"
    end
    r << "Connection: close\r\n" unless response.headers.has_key?("Connection")
    r << "\r\n"
    r << response.body.join("")
    r.join("")
  end

  def self.prepare_env(request, port)
    env = {
      'REQUEST_METHOD'    => request.request_method,
      'SCRIPT_NAME'       => '',
      'PATH_INFO'         => request.unparsed_uri,
      'QUERY_STRING'      => request.unparsed_uri.split('?').last || request.body,
      'SERVER_NAME'       => 'localhost',
      'SERVER_PORT'       => port.to_s,
      'rack.version'      => Rack.version.split('.'),
      'rack.url_scheme'   => 'http',
      'rack.input'        => StringIO.new(request.body || "", 'rb').set_encoding(Encoding::ASCII_8BIT),
      'rack.errors'       => StringIO.new(''),
      'rack.multithread'  => false,
      'rack.multiprocess' => true,
      'rack.run_once'     => true,
      'rack.hijack?'      => false
    }
    request.each do |k, v|
      key = k.start_with?('HTTP_') ? k : "HTTP_#{k}"
      env[key] = v
    end
    env
  end

  def respond_with_error(client_fd, text, status_code, headers={ 'Content-Type' => 'text/plain' })
    response = Rack::Response.new("#{text}\n", status_code, headers)
    client_fd.write(MyHttpServer.response_to_s(response))
  end

  def start
    @listening_socket = Socket.new(Socket::PF_INET, Socket::SOCK_STREAM, 0)
    @listening_socket.bind(Addrinfo.tcp(@host, @port))
    @listening_socket.listen(LISTENING_QUEUE_SIZE)
    @pids = @workers.times.map do
      fork do
        loop do
          client_fd, client_addr = @listening_socket.accept
          begin
            req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
            req.parse(client_fd)
            env = MyHttpServer.prepare_env(req, @port)
            tuple = @app.call(env)
            response = Rack::Response.new(tuple[2], tuple[0], tuple[1])
            client_fd.write(MyHttpServer.response_to_s(response))
          rescue WEBrick::HTTPStatus::RequestTimeout
            respond_with_error(client_fd, "Timeout. Max time exceeded.", 408)
          rescue Exception => e
            respond_with_error(client_fd, "Internal Server Error", 500)
            STDERR.puts(e, e.backtrace)
          ensure
            client_fd.shutdown(Socket::SHUT_RDWR)
            client_fd.close
          end
        end
      end
    end

    @pids.each do |p|
      Process.wait(p, Process::WNOHANG)
    end
  end

  def shutdown
    @listening_socket.shutdown(Socket::SHUT_RDWR)
    @pids.each do |pid|
      Process.kill(:TERM, pid)
    end
    @listening_socket.close
  end
end

class MyUnicornHandler
  def self.run(app, options={})
    host = options[:host] || "0.0.0.0"
    port = options[:port] || 3000
    workers = options[:workers] || 2
    server = MyHttpServer.new(app, host, port, workers)
    yield server if block_given?
    server.start
  end
end

module Rack
  module Handler
    register 'myunicorn', 'MyUnicornHandler'
  end
end

def run(app)
  MyUnicornHandler.run(app)
end
