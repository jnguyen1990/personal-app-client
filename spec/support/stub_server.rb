require "webrick"
require "json"

class StubServer
  attr_reader :port, :requests

  def initialize
    @port = find_free_port
    @routes = {}
    @requests = []
    @server = WEBrick::HTTPServer.new(
      Port: @port,
      BindAddress: "127.0.0.1",
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: []
    )
    @server.mount_proc "/" do |req, res|
      @requests << {
        method: req.request_method,
        path: req.path,
        query: req.query_string,
        headers: req.header.transform_values { |v| v.first },
        body: req.body
      }
      key = [req.request_method, req.path]
      handler = @routes[key] || @routes[[req.request_method, :any]]
      if handler
        handler.call(req, res)
      else
        res.status = 404
        res.body = "no stub"
      end
    end
    @thread = Thread.new { @server.start }
    wait_until_ready
  end

  def url
    "http://127.0.0.1:#{@port}"
  end

  def on(method, path, &block)
    @routes[[method.to_s.upcase, path]] = block
  end

  def stop
    @server.shutdown
    @thread.join(2)
  end

  private

  def find_free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_until_ready
    20.times do
      TCPSocket.new("127.0.0.1", @port).close
      return
    rescue Errno::ECONNREFUSED
      sleep 0.05
    end
    raise "stub server didn't start"
  end
end
