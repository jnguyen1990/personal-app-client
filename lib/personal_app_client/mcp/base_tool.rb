require "date"
require "active_support/core_ext/object/blank"
require_relative "../dates"

module PersonalAppClient
  module Mcp
    # Shared base class for MCP tools across the personal apps.
    # Tools inherit class-level metadata + a `self.call(args)` method.
    # Subclasses override `tool_name`, `description`, `input_schema`, and `call`.
    #
    # Apps alias (or subclass) this as their app-local `Mcp::BaseTool`:
    #
    #     # app/services/mcp/base_tool.rb
    #     require "personal_app_client/mcp/base_tool"
    #
    #     module Mcp
    #       BaseTool = PersonalAppClient::Mcp::BaseTool
    #     end
    #
    # Apps with extra helpers subclass instead and add/override methods.
    class BaseTool
      class << self
        def tool_name = raise NotImplementedError
        def description = raise NotImplementedError
        def input_schema = { type: "object", properties: {} }

        def call(_args)
          raise NotImplementedError
        end

        def descriptor
          { name: tool_name, description: description, inputSchema: input_schema }
        end

        # Helpers shared by tools.
        #
        # Dates are strict: exactly YYYY-MM-DD and a real calendar day. This
        # used to be Date.parse, which reads "05" as the 5th of the current
        # month and "next tuesday" as a real date — a tool would then act on
        # a day nobody asked for instead of telling Claude the argument was
        # malformed.
        def parse_date(value, default: nil)
          return default if value.blank?
          PersonalAppClient::Dates.parse_date(value) ||
            raise(ArgumentError, "Invalid date: #{value.inspect} (expected YYYY-MM-DD)")
        end

        # Same check for a named argument, with the key in the message:
        # nil when args[key] is blank, a Date when valid, ArgumentError
        # otherwise.
        def parse_date_arg!(args, key)
          value = args[key]
          return nil if value.blank?
          unless value.to_s.match?(PersonalAppClient::Dates::DATE_FORMAT)
            raise ArgumentError, "#{key} must be YYYY-MM-DD, got #{value.inspect}"
          end
          PersonalAppClient::Dates.parse_date(value) ||
            raise(ArgumentError, "#{key} is not a real date: #{value.inspect}")
        end

        def parse_time(value)
          return nil if value.blank?
          Time.zone.parse(value.to_s) || raise(ArgumentError, "Invalid timestamp: #{value.inspect}")
        end

        def clamp_int(value, default:, min: 1, max: 100)
          n = value.to_i
          n = default if n <= 0
          n.clamp(min, max)
        end
      end
    end
  end
end
