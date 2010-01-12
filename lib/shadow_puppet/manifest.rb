module ShadowPuppet
  # A Manifest is an executable collection of Puppet Resources[http://reductivelabs.com/trac/puppet/wiki/TypeReference].
  #
  # ===Example
  #
  #   class ManifestExample < ShadowPuppet::Manifest
  #     recipe :sample
  #     recipe :lamp, :ruby               # queue calls to self.lamp and
  #                                       # self.ruby when executing
  #
  #     recipe :mysql, {                  # queue a call to self.mysql
  #       :root_password => 'OMGSEKRET'   # passing the provided hash
  #     }                                 # as an option
  #
  #     def sample
  #       exec :foo, :command => 'echo "foo" > /tmp/foo.txt'
  #
  #       package :foo, :ensure => :installed
  #
  #       file '/tmp/example.txt',
  #         :ensure   => :present,
  #         :contents => Facter.to_hash_inspect,
  #         :require  => package(:foo)
  #     end
  #
  #     def lamp
  #       #install a basic LAMP stack
  #     end
  #
  #     def ruby
  #       #install a ruby interpreter and tools
  #     end
  #
  #     def mysql(options)
  #        #install a mysql server and set the root password to options[:root_password]
  #     end
  #
  #   end
  #
  # To execute the above manifest, instantiate it and call execute on it:
  #
  #   m = ManifestExample.new
  #   m.execute
  #
  # As shown in the +sample+ method in ManifestExample above, instance
  # methods are created for each Puppet::Type available on your system. These
  # methods behave identally to the Puppet Resources methods. See here[http://reductivelabs.com/trac/puppet/wiki/TypeReference]
  # for documentation on these methods.
  #
  # To view a list of all defined methods on your system, run:
  #
  #    ruby -rubygems -e 'require "shadow_puppet";puts ShadowPuppet::Manifest.puppet_type_methods'
  #
  # The use of methods (+sample+, +lamp+, +ruby+, and +mysql+ above) as a
  # container for resources facilitates recipie re-use through the use of Ruby
  # Modules. For example:
  #
  #   module ApachePuppet
  #     # Required options:
  #     #   domain
  #     #   path
  #     def php_vhost(options)
  #       #...
  #     end
  #    end
  #
  #   class MyWebMainfest < ShadowPuppet::Manifest
  #     include ApachePuppet
  #     recipe :php_vhost, {
  #       :domain => 'foo.com',
  #       :path => '/var/www/apps/foo'
  #     }
  #   end
  #
  # ==Testing
  #
  # To test that your manifest logic is working as intended, you should assert
  # that the proper puppet resources exist:
  #
  #   manifest.execs('wget mysqltuner.pl')
  #   manifest.packages('sshd')
  #
  # You can also access resource parameters as hash keys on the resource::
  #
  #   manifest.files('/etc/motd')[:content]
  #   manifest.execs('service ssh restart')[:onlyif]
  #
  # ===Test::Unit Example
  #
  # Given this manifest:
  #
  #   class TestedManifest < ShadowPuppet::Manifest
  #     def myrecipe
  #       file '/etc/motd', :content => 'Welcome to the machine!', :mode => '644'
  #       exec 'newaliases', :refreshonly => true
  #     end
  #     recipe :myrecipe
  #   end
  #
  # A test for the manifest could look like this:
  #
  #   manifest = TestedManifest.new
  #   manifest.myrecipe
  #   assert_match /Welcome/, manifest.files('/etc/motd')[:content]
  #   assert manifest.execs('newaliases')[:refreshonly]
  #
  class Manifest

    class_inheritable_accessor :recipes
    write_inheritable_attribute(:recipes, [])
    attr_reader :catalog, :compiler, :scope, :node
    class_inheritable_accessor :__config__
    write_inheritable_attribute(:__config__, Hash.new)

    # Initialize a new instance of this manifest. This can take a
    # config hash, which is immediately passed on to the configure
    # method
    def initialize(config = {})
      if Process.uid == 0
        Puppet[:confdir] = File.expand_path("/etc/shadow_puppet")
        Puppet[:vardir] = File.expand_path("/var/shadow_puppet")
      else
        Puppet[:confdir] = File.expand_path("~/.shadow_puppet")
        Puppet[:vardir] = File.expand_path("~/.shadow_puppet/var")
      end
      Puppet[:user] = Process.uid
      Puppet[:group] = Process.gid
      Puppet::Util::Log.newdestination(:console)

      configure(config)
      @executed = false

      # This is only needed to create the compiler.
      @node = Puppet::Node.new(Puppet[:certname])

      # Need a parser to have the main class
      @parser = Puppet::Parser::Parser.new(:environment => Puppet[:environment])

      # Create a 'main' class to be the "source" for all of the resources.
      @main_class = @parser.newclass("") unless @parser.find_hostclass("", "")

      # This does all of our initialization for us.
      @compiler = Puppet::Parser::Compiler.new(@node, @parser)

      # Maintains references to our resources
      @catalog = @compiler.catalog

      # Parser resources need a scope (and a source, which this has)
      @scope = @compiler.topscope
      @scope.source = @main_class
    end

    # Declares that the named method or methods will be called whenever
    # execute is called on an instance of this class. If the last argument is
    # a Hash, this hash is passed as an argument to all provided methods.
    # If no options hash is provided, each method is passed the contents of
    # <tt>configuration[method]</tt>.
    #
    # Subclasses of the Manifest class properly inherit the parent classes'
    # calls to recipe.
    def self.recipe(*methods)
      return nil if methods.nil? || methods == []
      options = methods.extract_options!
      methods.each do |meth|
        options = configuration[meth.to_sym] if options == {}
        options ||= {}
        recipes << [meth.to_sym, options]
      end
    end

    # A hash describing any configuration that has been
    # performed on the class. Modify this hash by calling configure:
    #
    #   class SampleManifest < ShadowPuppet::Manifest
    #     configure(:name => 'test')
    #   end
    #
    #   >> SampleManifest.configuration
    #   => {:name => 'test'}
    #
    # All keys on this hash are coerced into symbols for ease of access.
    #
    # Subclasses of the Manifest class properly inherit the parent classes'
    # configuration.
    def self.configuration
      __config__.deep_symbolize_keys
    end

    # Access to the configuration of the class of this instance.
    #
    #   class SampleManifest < ShadowPuppet::Manifest
    #     configure(:name => 'test')
    #   end
    #
    #   @manifest = SampleManifest.new
    #   @manifest.configuration[:name] => "test"
    def configuration
      self.class.configuration
    end

    # Define configuration on this manifest. This is useful for storing things
    # such as hostnames, password, or usernames that may change between
    # different implementations of a shared manifest. Access this hash by
    # calling <tt>configuration</tt>:
    #
    #   class SampleManifest < ShadowPuppet::Manifest
    #     configure('name' => 'test')
    #   end
    #
    #   >> SampleManifest.configuration
    #   => {:name => 'test'}
    #
    # All keys on this hash are coerced into symbols for ease of access.
    #
    # Subsequent calls to configure perform a deep_merge of the provided
    # <tt>hash</tt> into the pre-existing configuration.
    def self.configure(hash)
      __config__.deep_merge!(hash)
    end

    # Update the configuration of this manifest instance's class.
    #
    #   class SampleManifest < ShadowPuppet::Manifest
    #     configure({})
    #   end
    #
    #   @manifest = SampleManifest.new
    #   @manifest.configure(:name => "test")
    #   @manifest.configuration[:name] => "test"
    def configure(hash)
      self.class.configure(hash)
    end
    alias_method :configuration=, :configure

    #An array of all methods defined for creation of Puppet Resources
    def self.puppet_type_methods
      Puppet::Type.eachtype { |t| t.name }.keys.map { |n| n.to_s }.sort.inspect
    end

    def name
      @name ||= "#{self.class}##{self.object_id}"
    end

    #Create an instance method for every type that either creates or references
    #a resource
    def self.register_puppet_types
      Puppet::Type.loadall
      Puppet::Type.eachtype do |type|
        #remove the method rdoc placeholders
        remove_method(type.name) rescue nil
        define_method(type.name) do |*args|
          if args && args.flatten.size == 1
            reference(type.name, args.first)
          else
            create_or_update_resource(type, args.first, args.last)
          end
        end
      end
    end
    register_puppet_types

    # Returns true if this Manifest <tt>respond_to?</tt> all methods named by
    # calls to recipe, and if this Manifest has not been executed before.
    def executable?
      self.class.recipes.each do |meth,args|
        return false unless respond_to?(meth)
      end
      return false if executed?
      true
    end

    def missing_recipes
      missing = self.class.recipes.each do |meth,args|
        !respond_to?(meth)
      end
    end

    # Execute this manifest, applying all resources defined. Execute returns
    # true if successfull, and false if unsucessfull. By default, this
    # will only execute a manifest that has not already been executed?.
    # The +force+ argument, if true, removes this check.
    def execute(force=false)
      return false if executed? && !force
      evaluate_recipes
      apply
    rescue Exception => e
      false
    else
      true
    ensure
      @executed = true
    end

    # Execute this manifest, applying all resources defined. Execute returns
    # true if successfull, and raises an exception if not. By default, this
    # will only execute a manifest that has not already been executed?.
    # The +force+ argument, if true, removes this check.
    def execute!(force=false)
      return false if executed? && !force
      evaluate_recipes
      apply
    rescue Exception => e
      raise e
    else
      true
    ensure
      @executed = true
    end

    protected

    #Has this manifest instance been executed?
    def executed?
      @executed
    end

    private

    #Evaluate the methods calls queued in self.recipes
    def evaluate_recipes
      self.class.recipes.each do |meth, args|
        case arity = method(meth).arity
        when 1, -1
          send(meth, args)
        else
          send(meth)
        end
      end
    end

    # Apply and clear the catalog
    def apply
      # Convert our Puppet::Parser::Resource instances into Puppet::Type instances,
      # which can actually do work on the system.
      newcatalog = catalog.to_ral
      newcatalog.apply
    end

    # Create a reference to another Puppet Resource.
    def reference(type, title)
      if title
        ref = Puppet::Resource::Reference.new(type, title)
      else
        ref = Puppet::Resource::Reference.new(nil, type)
      end
    end

    # Refer to a named puppet resource
    def resource(type, title)
      catalog.resource(type,title)
    end

    # Create a Puppet Resource
    def new_resource(type, title, params = {})
      params.merge!({:title => title})
      params.merge!({:path => ENV["PATH"]}) if type.name == :exec

      # We want to create a Parser resource, because that's what
      # the new builtin DSL does.  Our 'apply' method converts them,
      # if necessary.
      resource = Puppet::Parser::Resource.new(:type => type, :title => title, :scope => scope)

      # The next release will have []/[]= methods.
      params.each do |param, value|
          resource.set_parameter(param, value)
      end

      # Add the resource to our catalog via the compiler.
      compiler.add_resource resource
    end

    #Creates or update a new Puppet Resource.
    def create_or_update_resource(type, title, params = {})
      if resource = resource(type.name, title)
        params.each do |param, value|
          resource.set_parameter(param, value)
        end
      else
        resource = new_resource(type, title, params)
      end
      resource
    end

  end
end

Dir.glob(File.join(File.dirname(__FILE__), '..', 'facts', '*.rb')).each do |fact|
  require fact
end
