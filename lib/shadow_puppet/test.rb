module ShadowPuppet
  class Manifest
    # Creates an pluralized instance method for every puppet type that
    # references existing resources
    def self.register_puppet_types_for_testing
      Puppet::Type.loadall
      Puppet::Type.eachtype do |type|
        plural_type = type.name.to_s.downcase.pluralize
        #undefine the method rdoc placeholders
        undef_method(plural_type) rescue nil

        # execs['wget mysqltuner.pl']
        define_method(plural_type+'[]') do |resource_name|
          resource(type.name.to_s.downcase,resource_name)
        end

        define_method(plural_type) do |*args|
          if args && args.flatten.size == 1
            # execs('wget mysqltuner.pl')
            send("#{plural_type}[]".intern, args.first)
          else
            # execs.keys.include?('wget mysqltuner.pl')
            resources = catalog.instance_variable_get(:@resource_table)
            typed_resources = resources.values.find_all { |value| value.is_a?(type) }
            named_hash = {}
            typed_resources.each do |resource|
              named_hash[resource.title] = resource
            end
            named_hash
          end
        end
      end
    end
    register_puppet_types_for_testing
  end
end