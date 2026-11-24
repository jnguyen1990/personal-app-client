require "active_support/concern"
require "active_support/core_ext/class/attribute"
require "net/http"
require "socket"
require_relative "../errors"

module PersonalAppClient
  module Rails
    # Retry a background job a few times when it fails on something that
    # passes by itself — a network blip to a sibling app, base restarting
    # for a deploy, SQLite briefly locked by another writer (PLAT-59). Without
    # it a job that hit one of these failed outright until its next scheduled
    # run (a day, for the nightly ones).
    #
    #     class ApplicationJob < ActiveJob::Base
    #       include PersonalAppClient::Rails::JobStatusReporting
    #       include PersonalAppClient::Rails::TransientRetries
    #     end
    #
    # ATTEMPTS runs in all (the first plus two retries), backing off
    # polynomially (~3s, ~18s). A retried job runs its whole perform again,
    # so it must be safe to repeat — the sync jobs are upserts, and the
    # client no longer re-sends a non-idempotent POST on a dropped connection
    # (Client::DROPPED_ERRORS). A job that is not safe to repeat opts out with
    # `discard_on` / its own `retry_on`, which take precedence (declared later).
    #
    # With JobStatusReporting, an attempt that will be retried reports
    # nothing; the final attempt reports ok or fail as before.
    module TransientRetries
      extend ActiveSupport::Concern

      ATTEMPTS = 3

      def self.errors
        list = [
          PersonalAppClient::ConnectionError, PersonalAppClient::TimeoutError,
          Net::OpenTimeout, Net::ReadTimeout,
          Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, SocketError
        ]
        # SQLite's "database is locked" (SQLite3::BusyException) surfaces as
        # StatementTimeout; a pool checkout timeout is the same kind of wait.
        list << ActiveRecord::StatementTimeout if defined?(ActiveRecord::StatementTimeout)
        list << ActiveRecord::ConnectionTimeoutError if defined?(ActiveRecord::ConnectionTimeoutError)
        list.freeze
      end

      included do
        # The list as it stood when the job class was defined: retry_on keys
        # its attempt counter on the list's to_s, so the check below must use
        # the very same list.
        class_attribute :transient_retry_errors, instance_writer: false, default: TransientRetries.errors
        retry_on(*transient_retry_errors, wait: :polynomially_longer, attempts: ATTEMPTS)
      end

      # True when this failure will be retried by the rule above. ActiveJob
      # counts retry_on attempts per exception list in exception_executions
      # (keyed by the list's to_s); the handler bumps it after this check.
      def transient_retry_pending?(error)
        return false unless transient_retry_errors.any? { |k| error.is_a?(k) }

        done = (exception_executions || {})[transient_retry_errors.to_s].to_i
        done + 1 < ATTEMPTS
      end
    end
  end
end
