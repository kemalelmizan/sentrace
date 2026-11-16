module Sentrace
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    class << self
      def sentrace_enum(attr_name, mapping, default: nil, prefix: nil)
        attr_sym = attr_name.to_sym

        if ActiveRecord.gem_version >= Gem::Version.new("7.1")
          options = { validate: true }
          options[:default] = default unless default.nil?
          options[:prefix] = prefix unless prefix.nil?
          enum(attr_sym, mapping, **options)
        else
          define_legacy_validated_enum(attr_sym, mapping, default: default, prefix: prefix)
        end
      end

      private
        def define_legacy_validated_enum(attr_sym, mapping, default:, prefix:)
          if ActiveRecord.gem_version >= Gem::Version.new("7.0")
            options = {}
            options[:default] = default unless default.nil?
            options[:prefix] = prefix unless prefix.nil?
            enum(attr_sym, mapping, **options)
          else
            legacy_options = { attr_sym => mapping }
            legacy_options[:_default] = default unless default.nil?
            legacy_options[:_prefix] = prefix unless prefix.nil?
            enum(legacy_options)
          end

          install_enum_validation_shim(attr_sym, mapping)
        end

        def install_enum_validation_shim(attr_sym, mapping)
          invalid_ivar = :"@_invalid_#{attr_sym}_value"
          valid_names = mapping.keys.map(&:to_s).freeze

          define_method(:"#{attr_sym}=") do |raw_value|
            super(raw_value)
            remove_instance_variable(invalid_ivar) if instance_variable_defined?(invalid_ivar)
          rescue ArgumentError
            super(nil)
            instance_variable_set(invalid_ivar, raw_value)
          end

          validate do
            current = public_send(attr_sym)
            if instance_variable_defined?(invalid_ivar) || current.nil? || !valid_names.include?(current.to_s)
              errors.add(attr_sym, :inclusion)
            end
          end
        end
    end
  end
end
