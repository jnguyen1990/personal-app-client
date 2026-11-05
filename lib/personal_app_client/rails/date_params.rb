require "active_support/concern"
require_relative "../dates"

module PersonalAppClient
  module Rails
    # Strict date parameters for controllers. Both helpers return nil for
    # anything that is not exactly the documented shape AND a real calendar
    # date — never a guess (see PersonalAppClient::Dates for why Date.parse is
    # the wrong tool on user input). Callers turn nil into a 400 or a default:
    #
    #     class ApplicationController < ActionController::Base
    #       include PersonalAppClient::Rails::DateParams
    #     end
    #
    #     date  = parse_date_param(params[:date]) || Date.current
    #     month = parse_month_param(params[:month]) or return invalid_month!
    module DateParams
      extend ActiveSupport::Concern

      DATE_PARAM_FORMAT  = PersonalAppClient::Dates::DATE_FORMAT
      MONTH_PARAM_FORMAT = PersonalAppClient::Dates::MONTH_FORMAT

      private

      # "YYYY-MM-DD" → Date, else nil.
      def parse_date_param(value)
        PersonalAppClient::Dates.parse_date(value)
      end

      # "YYYY-MM" → Date for the first of that month, else nil.
      def parse_month_param(value)
        PersonalAppClient::Dates.parse_month(value)
      end
    end
  end
end
