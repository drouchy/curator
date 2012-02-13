require 'active_support/inflector'
require 'active_support/core_ext/object/instance_variables'
require 'active_support/core_ext/hash/indifferent_access'
require 'json'

module Curator
  module Repository
    extend ActiveSupport::Concern

    module ClassMethods
      def collection_name
        ActiveSupport::Inflector.tableize(klass)
      end

      def data_store
        @data_store ||= Riak::DataStore
      end

      def data_store=(store)
        @data_store = store
      end

      def delete(object)
        data_store.delete(collection_name, object.id)
      end

      def encrypted_entity
        @encrypted_entity = true
      end

      def find_by_created_at(start_time, end_time)
        _find_by_index(collection_name, :created_at, _format_time_for_index(start_time).._format_time_for_index(end_time))
      end

      def find_by_updated_at(start_time, end_time)
        _find_by_index(collection_name, :updated_at, _format_time_for_index(start_time).._format_time_for_index(end_time))
      end

      def find_by_id(id)
        if hash = data_store.find_by_key(collection_name, id)
          _deserialize(hash[:key], hash[:data])
        end
      end

      def indexed_fields(*fields)
        @indexed_fields = fields

        @indexed_fields.each do |field_name|
          _build_finder_methods(field_name)
        end
      end

      def klass
        name.to_s.gsub("Repository", "").constantize
      end

      def migrator
        @migrator ||= Curator::Migrator.new(collection_name)
      end

      def save(object)
        hash = {
          :collection_name => collection_name,
          :value => _serialize(object),
          :index => _indexes(object)
        }

        if object.id
          hash[:key] = object.id
          data_store.save(hash)
        else
          object.id = data_store.save(hash).key
        end
      end

      def serialize(object)
        object.instance_values
      end

      def _build_finder_methods(field_name)
        singleton_class.class_eval do
          define_method("find_by_#{field_name}") do |value|
            _find_by_index(collection_name, field_name, value)
          end
          define_method("find_first_by_#{field_name}") do |value|
            _find_by_index(collection_name, field_name, value).first
          end
        end
      end

      def _find_by_index(collection_name, field_name, value)
        if results = data_store.find_by_index(collection_name, field_name, value)
          results.map do |hash|
            _deserialize(hash[:key], hash[:data])
          end
        end
      end

      def deserialize(attributes)
        klass.new(attributes)
      end

      def _deserialize(id, data)
        attributes = data.with_indifferent_access
        migrated_attributes = migrator.migrate(attributes)
        object = deserialize(migrated_attributes)
        object.id = id
        object.created_at = Time.parse(attributes[:created_at]) if attributes[:created_at].present?
        object.updated_at = Time.parse(attributes[:updated_at]) if attributes[:updated_at].present?
        object
      end

      def _encrypted_attributes(object, attributes)
        return attributes unless _encrypted_entity?

        encryption_key = EncryptionKeyRepository.find_active
        plaintext = attributes.to_json
        ciphertext = encryption_key.encrypt(plaintext)
        {
          :encryption_key_id => encryption_key.id,
          :encrypted_data => Base64.encode64(ciphertext)
        }
      end

      def _encrypted_entity?
        @encrypted_entity == true
      end

      def _format_time_for_index(time)
        time.to_json.gsub('"', '')
      end

      def _indexed_fields
        @indexed_fields || []
      end

      def _indexes(object)
        index_values = _indexed_fields.map { |field| [field, object.send(field)] }
        index_values += [
          [:created_at, _format_time_for_index(object.send(:created_at))],
          [:updated_at, _format_time_for_index(object.send(:updated_at))]
        ]
        Hash[index_values]
      end

      def _serialize(object)
        attributes = serialize(object).reject { |key, val| val.nil? }

        timestamp = Time.now.utc

        updated_at = timestamp
        created_at = object.created_at || timestamp

        object.created_at = created_at
        object.updated_at = updated_at
        attributes[:created_at] = created_at
        attributes[:updated_at] = updated_at

        _encrypted_attributes(object, attributes)
      end
    end
  end
end