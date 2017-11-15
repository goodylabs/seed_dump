class SeedDump
  module DumpMethods
    include Enumeration

    def dump(records, options = {})
      return nil if records.count == 0

      io = open_io(options)

      write_records_to_io(records, io, options)

      ensure
        io.close if io.present?
    end

    private

    def underscore(camel_cased_word)
     camel_cased_word.to_s.gsub(/::/, '/').
       gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2').
       gsub(/([a-z\d])([A-Z])/,'\1_\2').
       tr("-", "_").
       downcase
    end

    def dump_record(record, options)
      attribute_strings = []

      # We select only string attribute names to avoid conflict
      # with the composite_primary_keys gem (it returns composite
      # primary key attribute names as hashes).
      record.attributes.select {|key| key.is_a?(String) }.each do |attribute, value|
        attribute_strings << dump_attribute_new(attribute, value, options) unless options[:exclude].include?(attribute.to_sym)
      end

      open_character, close_character = options[:import] ? ['[', ']'] : ['{', '}']

      "#{open_character}#{attribute_strings.join(", ")}#{close_character}"
    end

    def dump_attribute_new(attribute, value, options)
      options[:import] ? value_to_s(value) : "#{attribute}: #{value_to_s(value)}"
    end

    def value_to_s(value)
      value = case value
              when BigDecimal, IPAddr
                value.to_s
              when Date, Time, DateTime
                value.to_s(:db)
              when Range
                range_to_string(value)
              when ->(v) { v.class.ancestors.map(&:to_s).include?('RGeo::Feature::Instance') }
                value.to_s
              else
                value
              end

      value.inspect
    end

    def range_to_string(object)
      from = object.begin.respond_to?(:infinite?) && object.begin.infinite? ? '' : object.begin
      to   = object.end.respond_to?(:infinite?) && object.end.infinite? ? '' : object.end
      "[#{from},#{to}#{object.exclude_end? ? ')' : ']'}"
    end

    def open_io(options)
      if options[:file].present?
        mode = options[:append] ? 'a+' : 'w+'

        File.open(options[:file], mode)
      else
        StringIO.new('', 'w+')
      end
    end

    def write_records_to_io(records, io, options)
      options[:exclude] ||= [:id, :created_at, :updated_at]

      model_name = "#{model_for(records)}";
      var_name = underscore(model_name);

      io.write(var_name + " = ")
      if options[:import]
        io.write("[#{attribute_names(records, options).map {|name| name.to_sym.inspect}.join(', ')}], ")
      end
      io.write("[\n  ")

      enumeration_method = if records.is_a?(ActiveRecord::Relation) || records.is_a?(Class)
                             :active_record_enumeration
                           else
                             :enumerable_enumeration
                           end

      send(enumeration_method, records, io, options) do |record_strings, last_batch|
        io.write(record_strings.join(",\n  "))

        io.write(",\n  ") unless last_batch
      end

      io.write("\n]\n")

      update_code = """
[var_name].each do |f|
  item = [model_name].find_by_key(f[:key])
  unless item.nil?
    item.update_attributes(f)
    item.save
  else
    [model_name].create!(f)
  end
end
"""
      update_code = update_code.gsub(/[model_name]/g, model_name).gsub(/[var_name]/g, var_name)

      io.write(update_code)

      if options[:file].present?
        nil
      else
        io.rewind
        io.read
      end
    end

    def attribute_names(records, options)
      attribute_names = if records.is_a?(ActiveRecord::Relation) || records.is_a?(Class)
                          records.attribute_names
                        else
                          records[0].attribute_names
                        end

      attribute_names.select {|name| !options[:exclude].include?(name.to_sym)}
    end

    def model_for(records)
      if records.is_a?(Class)
        records
      elsif records.respond_to?(:model)
        records.model
      else
        records[0].class
      end
    end

  end
end
