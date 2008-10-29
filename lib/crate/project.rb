require 'rake'
require 'rake/tasklib'
require 'amalgalite'
require 'amalgalite/requires'

module Crate
  #
  # the Crate top level task, there should only be one of these in existence at
  # a time.  This task is accessible via Crate.project, and is what is defined
  # in the Rakefile in the project directory.
  #
  class Project < ::Rake::TaskLib
    # Name of the project
    attr_reader :name

    # Top level directory of the project. 
    attr_reader :project_root

    # subdirectory of +project_root+ in which the recipe's are stored.
    # default: 'recipes'
    attr_accessor :recipe_dir

    # subdirectory of +project_root+ where recipes' are built. default: 'build'
    attr_accessor :build_dir

    # subdirectory of +project_root+ representing a fake installation root.
    # default 'fakeroot'
    attr_accessor :install_dir

    # the directory where the final products are stored
    attr_accessor :dist_dir

    # The list of extensions to compile
    attr_reader :extensions

    def initialize( name ) 
      raise "Crate Project already initialized" if ::Crate.project
      @name         = name
      @project_root = File.expand_path( File.dirname( Rake.application.rakefile ) )
      @recipe_dir   = File.join( @project_root, 'recipes' )
      @build_dir    = File.join( @project_root, 'build' )
      @install_dir  = File.join( @project_root, 'fakeroot' )
      @dist_dir     = File.join( @project_root, 'dist' )
      yield self if block_given?
      ::Crate.project = self
      define
    end

    def recipe_dir=( rd )
      @recipe_dir = File.join( project_root, rd )
    end

    def build_dir=( bd )
      @build_dir = File.join( project_root, bd)
    end

    def install_dir=( id )
      @install_dir = File.join( project_root, id )
    end

    def dist_dir=( dd )
      @dist_dir = File.join( project_root, dd )
    end

    def extensions=( list )
      @extensions = list.select { |l| l.index("#").nil? }
    end

    #
    # Create a logger for the project
    #
    def logger
      unless @logger 
        @logger = Logging::Logger[name]
        @logger.level = :debug
        @logger.add_appenders

        @logger.add_appenders( 
            Logging::Appenders::File.new( File.join( project_root, "project.log" ), :layout => Logging::Layouts::Pattern.new( :pattern => "%d %5l: %m\n" )),
            Logging::Appenders::Stdout.new( 'stdout', :level => :info,
                                          :layout => Logging::Layouts::Pattern.new( :pattern      => "%d %5l: %m\n",
                                                                                    :date_pattern => "%H:%M:%S") )
        )
      end
      return @logger
    end

    #
    # Load upthe compile params we may need to compile the project.  This method
    # is usless until after the :ruby task has been completed
    #
    def compile_params 
      unless @compile_params
        @compile_params = {}
        Dir.chdir( ::Crate.ruby.pkg_dir ) do
          %w[ CC CFLAGS XCFLAGS LDFLAGS CPPFLAGS LIBS ].each do |p|
            @compile_params[p] = %x( ./miniruby -I. -rrbconfig -e 'puts Config::CONFIG["#{p}"]' ).strip
          end
        end
      end
      return @compile_params
    end

    # 
    # Compile the crate_boot stub to an object file
    #
    def compile_crate_boot
      compile_options = %w[ CFLAGS XCFLAGS CPPFLAGS ].collect { |c| compile_params[c] }.join(' ')
      cmd = "#{compile_params['CC']} #{compile_options} -I#{Crate.ruby.pkg_dir} -o crate_boot.o -c crate_boot.c"
      logger.debug cmd
      sh cmd
      ::CLEAN << "crate_boot.o"
    end

    #
    # Run the link command to create the final executable
    #
    def link_project
      link_options = %w[ CFLAGS XCFLAGS LDFLAGS ].collect { |c| compile_params[c] }.join(' ')
      Dir.chdir( ::Crate.ruby.pkg_dir ) do
        dot_a = FileList[ "**/*.a" ]
        dot_o = [ "ext/extinit.o", File.join( project_root, "crate_boot.o" )]
        libs = compile_params['LIBS']
        cmd = "#{compile_params['CC']} #{link_options} #{dot_o.join(' ')} #{dot_a.join(' ')} -o #{File.join( dist_dir, name) }"
        logger.debug cmd
        sh cmd
      end
    end

    #
    # define the project task
    #
    def define
      lib_db = File.join( dist_dir, "lib.db" )
      directory dist_dir

      task :pack_ruby => dist_dir do
        logger.info "Storing rubylib in #{lib_db}"
        ::Amalgalite::Requires.store_dir_in_db( File.join( ::Crate.ruby.pkg_dir, "lib" ), :dbfile => lib_db )
      end

      task :pack_amalgalite => dist_dir do
        cmd = "~/Projects/amalgalite/bin/amalgalite-pack-into-db --force #{lib_db}"
        logger.info cmd
        sh "#{cmd} > /dev/null"
      end

      file "crate_boot.o" => "crate_boot.c" do
        compile_crate_boot
      end

      app_path = File.join( dist_dir, name )
      file app_path => [ "crate_boot.o", dist_dir ] do
        link_project
      end

      desc "Build #{name}"
      #task :default => [ :ruby ] do 
      task :default => [ app_path, :pack_amalgalite, :pack_ruby ] do
        logger.info "Build #{name}"
        compile_crate_boot
        link_project
      end
      ::CLEAN << self.install_dir
      ::CLEAN << "project.log"
      ::CLEAN << self.dist_dir
      load_rakefiles
    end

    #
    # Load all .rake files that are in a recipe sub directory
    #
    def load_rakefiles
      Dir["#{recipe_dir}/*/*.rake"].each do |recipe|
        logger.debug "loading #{recipe}"
        import recipe
      end
    end
  end
end