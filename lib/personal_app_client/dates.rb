require "date"

module PersonalAppClient
  # Strict parsing for dates that arrive as text (params, MCP arguments).
  #
  # Date.parse is lenient in a way that is quietly dangerous on user input:
  # "abc-05" and "05" both come back as the 5th of the CURRENT month, and
  # "next tuesday" resolves to a real date — so a malformed value acts on a
  # date nobody asked for instead of failing. Check the shape, then parse
  # with an explicit format (strptime also rejects 2026-02-30, which a regex
  # alone cannot). Both methods return nil for anything they will not vouch
  # for; callers decide whether that is a 400, an ArgumentError or a default.
  module Dates
    DATE_FORMAT  = /\A\d{4}-\d{2}-\d{2}\z/
    MONTH_FORMAT = /\A\d{4}-(?:0[1-9]|1[0-2])\z/

    module_function

    # "YYYY-MM-DD" → Date, else nil.
    def parse_date(value)
      return nil unless value.to_s.match?(DATE_FORMAT)
      Date.strptime(value.to_s, "%Y-%m-%d")
    rescue Date::Error
      nil
    end

    # "YYYY-MM" → Date for the first of that month, else nil.
    def parse_month(value)
      return nil unless value.to_s.match?(MONTH_FORMAT)
      Date.strptime("#{value}-01", "%Y-%m-%d")
    rescue Date::Error
      nil
    end
  end
end
