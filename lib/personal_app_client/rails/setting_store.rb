require "active_support/concern"
require "active_support/core_ext/class/attribute"

module PersonalAppClient
  module Rails
    # The key/value `Setting` model every app carries (table `settings`,
    # string columns `key` and `value`).
    #
    #     class Setting < ApplicationRecord
    #       include PersonalAppClient::Rails::SettingStore
    #
    #       DEFAULTS = { "lead_days" => "14" }.freeze   # optional
    #     end
    #
    #   Setting.get(key, default = nil)  stored value, else DEFAULTS[key], else default
    #   Setting.set(key, value)          upsert (value stored as a String)
    #   Setting.bulk_update(hash)        set each pair
    #   Setting.int(key)                 get(key).to_i
    #   Setting.bool(key)                lenient: true / 1 / on / yes (any case)
    #   Setting.get_bool(key)            strict: exactly "true"
    #
    # The two boolean readers are the two the apps already had, kept under
    # their own names with their own semantics so no caller changes meaning.
    #
    # `set` returns the stored value. base and fitness returned the record
    # instead; they keep that with `self.setting_set_returns = :record`.
    module SettingStore
      extend ActiveSupport::Concern

      TRUTHY = %w[true 1 on yes].freeze

      included do
        class_attribute :setting_set_returns, instance_writer: false, default: :value
        validates :key, presence: true, uniqueness: true
      end

      class_methods do
        def get(key, default = nil)
          record = find_by(key: key)
          return record.value if record
          setting_defaults[key] || default
        end

        def set(key, value)
          record = find_or_initialize_by(key: key)
          record.value = value.to_s
          record.save!
          setting_set_returns == :record ? record : record.value
        end

        def bulk_update(hash)
          hash.each { |k, v| set(k, v) }
        end

        def bool(key)
          TRUTHY.include?(get(key).to_s.strip.downcase)
        end

        def get_bool(key)
          get(key) == "true"
        end

        def int(key)
          get(key).to_i
        end

        private

        # The including model's DEFAULTS constant, if it defines one.
        def setting_defaults
          const_defined?(:DEFAULTS) ? const_get(:DEFAULTS) : {}
        end
      end
    end
  end
end
