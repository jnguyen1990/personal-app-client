require "ostruct"

# Just enough of ActionController for the controller concerns: callback
# registration with only:/except:, a request with headers and cookies, and a
# `render` that records what it was given. `process(:action)` runs the
# before_actions the way Rails would (halting once something rendered) and
# then the action.
class FakeActionController
  class << self
    def filters
      @filters ||= superclass.respond_to?(:filters) ? superclass.filters.dup : []
    end

    def before_action(*names, **options)
      names.each { |name| filters << [ name, options ] }
    end

    def skip_before_action(*names, **_options)
      filters.reject! { |name, _| names.include?(name) }
    end

    def before_actions
      filters.map(&:first)
    end
  end

  attr_accessor :params
  attr_writer :request
  attr_reader :rendered

  def initialize(headers: {}, cookies: {}, params: {})
    @request = OpenStruct.new(headers: headers, cookies: cookies, base_url: "https://app.example.test")
    @params = params
  end

  def request
    @request
  end

  def render(payload)
    @rendered = payload
  end

  def performed?
    !@rendered.nil?
  end

  def process(action)
    self.class.filters.each do |name, options|
      next if options[:only] && !Array(options[:only]).include?(action)
      next if options[:except] && Array(options[:except]).include?(action)
      send(name)
      return self if performed?
    end
    send(action)
    self
  end
end
