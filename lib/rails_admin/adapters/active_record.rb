require 'active_record'
require 'rails_admin/adapters/active_record/abstract_object'

module RailsAdmin
  module Adapters
    module ActiveRecord
      DISABLED_COLUMN_TYPES = [:tsvector, :blob, :binary, :spatial, :hstore, :geometry]
      DISABLED_COLUMN_MATCHERS = [/_array$/]

      def ar_adapter
        Rails.configuration.database_configuration[Rails.env]['adapter']
      end

      def like_operator
        ar_adapter == "postgresql" ? 'ILIKE' : 'LIKE'
      end

      def new(params = {})
        AbstractObject.new(model.new(params))
      end

      def get(id)
        if object = model.where(primary_key => id).first
          AbstractObject.new object
        end
      end

      def scoped
        model.all
      end

      def first(options = {}, scope = nil)
        all(options, scope).first
      end

      def all(options = {}, scope = nil)
        scope ||= self.scoped
        scope = scope.includes(options[:include]) if options[:include]
        scope = scope.limit(options[:limit]) if options[:limit]
        scope = scope.where(primary_key => options[:bulk_ids]) if options[:bulk_ids]
        scope = query_scope(scope, options[:query]) if options[:query]
        scope = filter_scope(scope, options[:filters]) if options[:filters]
        if options[:page] && options[:per]
          scope = scope.send(Kaminari.config.page_method_name, options[:page]).per(options[:per])
        end
        scope = scope.reorder("#{options[:sort]} #{options[:sort_reverse] ? 'asc' : 'desc'}") if options[:sort]
        scope
      end

      def count(options = {}, scope = nil)
        all(options.merge({:limit => false, :page => false}), scope).count
      end

      def destroy(objects)
        Array.wrap(objects).each &:destroy
      end

      def associations
        model.reflect_on_all_associations.map do |association|
          Association.new(association, model).to_options_hash
        end
      end

      def properties
        columns = model.columns.reject do |c|
          c.type.blank? ||
            DISABLED_COLUMN_TYPES.include?(c.type.to_sym) ||
            DISABLED_COLUMN_MATCHERS.any? {|matcher| matcher.match(c.type.to_s)}
        end
        columns.map do |property|
          {
            :name => property.name.to_sym,
            :pretty_name => property.name.to_s.tr('_', ' ').capitalize,
            :length => property.limit,
            :nullable? => property.null,
            :serial? => property.primary,
          }.merge(type_lookup(property))
        end
      end

      delegate :primary_key, :table_name, :to => :model, :prefix => false

      def encoding
        Rails.configuration.database_configuration[Rails.env]['encoding']
      end

      def embedded?
        false
      end

      def cyclic?
        false
      end

      def adapter_supports_joins?
        true
      end

      private

      def query_scope(scope, query, fields = config.list.fields.select(&:queryable?))
        statements = []
        values = []
        tables = []

        fields.each do |field|
          field.searchable_columns.flatten.each do |column_infos|
            statement, value1, value2 = build_statement(column_infos[:column], column_infos[:type], query, field.search_operator)
            statements << statement if statement
            values << value1 unless value1.nil?
            values << value2 unless value2.nil?
            table, column = column_infos[:column].split('.')
            tables.push(table) if column
          end
        end
        scope.where(statements.join(' OR '), *values).references(*(tables.uniq))
      end

      # filters example => {"string_field"=>{"0055"=>{"o"=>"like", "v"=>"test_value"}}, ...}
      # "0055" is the filter index, no use here. o is the operator, v the value
      def filter_scope(scope, filters, fields = config.list.fields.select(&:filterable?))
        filters.each_pair do |field_name, filters_dump|
          filters_dump.each do |filter_index, filter_dump|
            statements = []
            values = []
            tables = []
            fields.find{|f| f.name.to_s == field_name}.searchable_columns.each do |column_infos|
              statement, value1, value2 = build_statement(column_infos[:column], column_infos[:type], filter_dump[:v], (filter_dump[:o] || 'default'))
              statements << statement if statement.present?
              values << value1 unless value1.nil?
              values << value2 unless value2.nil?
              table, column = column_infos[:column].split('.')
              tables.push(table) if column
            end
            scope = scope.where(statements.join(' OR '), *values).references(*(tables.uniq))
          end
        end
        scope
      end

      def build_statement(column, type, value, operator)
        # this operator/value has been discarded (but kept in the dom to override the one stored in the various links of the page)
        return if operator == '_discard' || value == '_discard'

        # filtering data with unary operator, not type dependent
        if operator == '_blank' || value == '_blank'
          return ["(#{column} IS NULL OR #{column} = '')"]
        elsif operator == '_present' || value == '_present'
          return ["(#{column} IS NOT NULL AND #{column} != '')"]
        elsif operator == '_null' || value == '_null'
          return ["(#{column} IS NULL)"]
        elsif operator == '_not_null' || value == '_not_null'
          return ["(#{column} IS NOT NULL)"]
        elsif operator == '_empty' || value == '_empty'
          return ["(#{column} = '')"]
        elsif operator == '_not_empty' || value == '_not_empty'
          return ["(#{column} != '')"]
        end

        # now we go type specific
        case type
        when :boolean
          return ["(#{column} IS NULL OR #{column} = ?)", false] if %w[false f 0].include?(value)
          return ["(#{column} = ?)", true] if %w[true t 1].include?(value)
        when :integer, :decimal, :float
          case value
          when Array then
            val, range_begin, range_end = *value.map do |v|
              if (v.to_i.to_s == v || v.to_f.to_s == v)
                type == :integer ? v.to_i : v.to_f
              end
            end
            case operator
            when 'between'
              datetime_filter(column, range_begin, range_end)
            else
              ["(#{column} = ?)", val] if val
            end
          else
            if value.to_i.to_s == value || value.to_f.to_s == value
              type == :integer ? ["(#{column} = ?)", value.to_i] : ["(#{column} = ?)", value.to_f]
            end
          end
        when :belongs_to_association
          return if value.blank?
          ["(#{column} = ?)", value.to_i] if value.to_i.to_s == value
        when :string, :text
          return if value.blank?
          value = case operator
          when 'default', 'like'
            "%#{value.downcase}%"
          when 'starts_with'
            "#{value.downcase}%"
          when 'ends_with'
            "%#{value.downcase}"
          when 'is', '='
            "#{value.downcase}"
          else
            return
          end
          ["(LOWER(#{column}) #{like_operator} ?)", value]
        when :date
          datetime_filter(column, *get_filtering_duration(operator, value))
        when :datetime, :timestamp
          datetime_filter(column, *get_filtering_duration(operator, value), true)
        when :enum
          return if value.blank?
          ["(#{column} IN (?))", Array.wrap(value)]
        end
      end

      def datetime_filter(column, start_date, end_date, datetime = false)
        if datetime
          start_date = start_date.to_time.beginning_of_day if start_date
          end_date = end_date.to_time.end_of_day if end_date
        end

        if start_date && end_date
          ["(#{column} BETWEEN ? AND ?)", start_date, end_date]
        elsif start_date
          ["(#{column} >= ?)", start_date]
        elsif end_date
          ["(#{column} <= ?)", end_date]
        end
      end
      protected :datetime_filter

      def type_lookup(property)
        if model.serialized_attributes[property.name.to_s]
          {:type => :serialized}
        else
          {:type => property.type}
        end
      end

      private
      class Association
        attr_reader :association, :model

        def initialize(association, model)
          @association = association
          @model = model
        end

        def to_options_hash
          {
            :name => name.to_sym,
            :pretty_name => display_name,
            :type => macro,
            :model_proc => Proc.new { model_lookup },
            :primary_key_proc => Proc.new { primary_key_lookup },
            :foreign_key => foreign_key.to_sym,
            :foreign_type => foreign_type_lookup,
            :as => as_lookup,
            :polymorphic => polymorphic_lookup,
            :inverse_of => inverse_of_lookup,
            :read_only => read_only_lookup,
            :nested_form => nested_attributes_options_lookup
          }
        end

        private
        def model_lookup
          if options[:polymorphic]
            polymorphic_parents(:active_record, model_name.to_s, name) || []
          else
            klass
          end
        end

        def foreign_type_lookup
          options[:foreign_type].try(:to_sym) || :"#{name}_type" if options[:polymorphic]
        end

        def nested_attributes_options_lookup
          model.nested_attributes_options.try { |o| o[name.to_sym] }
        end

        def as_lookup
          options[:as].try :to_sym
        end

        def polymorphic_lookup
          !!options[:polymorphic]
        end

        def primary_key_lookup
          options[:primary_key] || klass.primary_key
        end

        def inverse_of_lookup
          options[:inverse_of].try :to_sym
        end

        def read_only_lookup
          klass.all.instance_eval(&scope).readonly_value if scope.is_a? Proc
        end

        def display_name
          name.to_s.tr('_', ' ').capitalize
        end

        delegate :klass, :macro, :name, :options, :scope, :foreign_key,
                 :to => :association, :prefix => false
        delegate :name, :to => :model, :prefix => true
        delegate :polymorphic_parents, :to => RailsAdmin::AbstractModel
      end
    end
  end
end
