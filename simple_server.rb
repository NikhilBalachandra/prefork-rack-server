require 'socket'

def unindent(s)
  s.gsub(/^#{s.scan(/^[ \t]+(?=\S)/).min}/, '')
end

def main
  s = Socket.new(Socket::PF_INET, Socket::SOCK_STREAM, 0)
  s.bind(Addrinfo.tcp("0.0.0.0", 8000))
  s.listen(1)
  loop do
    c, addr = s.accept()
    c.recv(1)
    c.write(unindent(%{
      HTTP/1.1 200 OK
      Content-Type: text/html
      Content-Length: 46

      <html><body><h1>Hello World</h1></body></html>
     }))
    c.close()
  end
end

main
