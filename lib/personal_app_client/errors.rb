module PersonalAppClient
  class Error < StandardError; end

  class ConfigurationError < Error; end

  class ResponseError < Error
    attr_reader :status, :body, :url

    def initialize(message, status:, body:, url:)
      super(message)
      @status = status
      @body = body
      @url = url
    end
  end

  class ConnectionError < Error; end
  class TimeoutError < Error; end
end
