# encoding: utf-8
require 'rubygems'
require 'securerandom'
require 'open-uri'
require 'active_support/core_ext/hash/indifferent_access'
require 'pp'
require 'shellwords'
require 'sshkit'
require 'pathname'

module Wp

  # Helper methods
  def self.is_wordpress(folder)
    File.exist?("#{folder}/wp-config.php")
  end

  def self.is_git(folder)
    File.directory?("#{folder}/.git")
  end

  def self.get_config()
    path = Pathname(Dir.pwd + "/config.yaml")
    if path.exist?
      return YAML::load(File.open(path.to_s)).with_indifferent_access
    else
      p "Missing config.yaml"
      abort
    end
  end

  def self.git_status(folder)
    folder_name = File.basename(folder)
    status = ""
    if Mwp::is_wordpress(folder) && Mwp::is_git(folder)
      f = open("|git --work-tree=#{folder} --git-dir=#{folder}/.git status | head -4")
      status = f.read
      f.close
      status.delete!("\n")
    end
    status
  end

  def self.git_clean(folder)
    if Mwp::git_status(folder).include? "nothing to commit"
      return true
    else
      return false
    end
  end

  def self.is_blank(str, default)
    str.nil? || str=="" ? default : str
  end

  def self.env_alt(env)
    env = "production" if env == "prod"
    env = "development" if env == "dev"
    env
  end

  class Wp_Cli < Thor
    include Thor::Actions
    include SSHKit::DSL

    default_task :command
    desc "command [-b=base] [-c=command] [-e=environment]", "WP Cli core commands"
    option :base, type: :string, aliases: "-b"
    option :command, type: :string, aliases: "-c"
    option :environment, type: :string, aliases: "-e"
    def command
      config = Wp::get_config
      environment = Wp::env_alt(options[:environment])
      base = options[:base]
      command = options[:command]
      if environment == "" || command == "" || base == ""
        say "Missing parameters"
        abort
      end

      host = SSHKit::Host.new({hostname: config[:ssh][environment][:server],
                                port: config[:ssh][environment][:port],
                                user: config[:ssh][environment][:user]})

      SSHKit.config.command_map[:wp] = "/usr/bin/wp"

      on host do |host|
        within config[:ssh][environment][:path] do
          #puts capture :wp, "#{base} #{command}"
          execute :wp, "#{base} #{command}"
        end
      end
    end

  end

  class Install < Thor

    include Thor::Actions

    default_task :wordpress

    desc "wordpress [-p=project_name]", "Download and install WordPress (default)"
    method_option :project, :type => :string, :aliases => "-p"
    def wordpress
      wp_dir = options[:project]

      if wp_dir == "new_project"
        say "Specify project name", :red
        say "Usage: thor wp:install --project=<project_name>"
        exit
      end

      config_file = wp_dir + "/config.yaml"
      if !File.exist?(config_file)
        run "thor wp:generate:config --dir=#{wp_dir}"
      end

      config = Wp::get_config

      # download WordPress
      run "cd #{wp_dir} && wp core download --locale=nb_NO"

      # create wp-config.php
      run "thor wp:generate:wp_config --dir=#{wp_dir}"

      # download new_relic.php
      run "thor wp:generate:new_relic --dir=#{wp_dir}"

      # setup git
      run "thor wp:generate:gitignore --dir=#{wp_dir}"
      run "cd #{wp_dir} && git init"

      say "---- Done. Next steps: ----", :green
      say "1. Setup config in config.yaml", :green
      say "2. In project root, run: $ thor wp:generate:local_config -e=dev", :green
      say "3. In project root, run: $ thor wp:setup:db -e=dev", :green
      say "Finally, Wordpress can be installed with wp-cli: wp core install --url=http://sites/SITEURL --title=SITE_TITLE --admin_name=USER_NAME --admin_password=PASSWORD --admin_email=ADMIN_EMAIL", :green

    end

    desc "theme", "Download and install Mediebruket Starter Theme"
    def theme
      run "cd wp-content/themes && git clone git@github.com:mediebruket/mb-starter-theme.git"
      run "rm -rf wp-content/themes/mb-starter-theme/.git"
    end

    desc "sendgrid", "Download and install WP Sendgrid"
    def sendgrid
      run "wp plugin install wp-sendgrid"
      say "Remember to activate and setup plugin in stage/production environment.", :yellow
    end
  end


  class Sync < Thor
    include Thor::Actions
    include SSHKit::DSL

    desc "db [-f=prod -t=dev -d=false]", "Syncs database to[-t] and from[-f] environments [-n]=false (network) [-p]=false (purged)"
    method_option :from, :type => :string, :aliases => "-f", :default => "production"
    method_option :to, :type => :string, :aliases => "-t", :default => "development"
    method_option :network, :type => :boolean, :aliases => "-n", :default => false
    method_option :purged, :type => :boolean, :aliases => "-p", :default => false
    def db
      config = Wp::get_config

      from = Wp::env_alt(options[:from])
      to = Wp::env_alt(options[:to])
      network = options[:network]
      purged = options[:purged]

      if from == "stage" || from == "production"
        from_host = SSHKit::Host.new({hostname: config[:ssh][from][:server],
                                  port: config[:ssh][from][:port],
                                  user: config[:ssh][from][:user]})
      end

      if to == "stage" || to == "production"
        to_host = SSHKit::Host.new({hostname: config[:ssh][to][:server],
                                  port: config[:ssh][to][:port],
                                  user: config[:ssh][to][:user]})
      end

      random = rand( 10 ** 5 ).to_s.rjust( 5, '0' )
      tempfile = "#{config[:database][from][:name]}-#{random}.sql"

      # dump
      cmd = "--single-transaction -u #{config[:database][from][:user]} -h localhost -p#{config[:database][from][:pass]} #{config[:database][from][:name]} > /tmp/#{tempfile}"
      if from == 'stage' || from == 'production'
        on from_host do |host|
          within config[:ssh][from][:path] do
            execute :mysqldump, cmd
            download! "/tmp/#{tempfile}", "/tmp/"
            execute :rm, "/tmp/#{tempfile}"
          end
        end
      else
        run "mysqldump " + cmd
      end

      # import
      cmd = "-u #{config[:database][to][:user]} -h localhost -p#{config[:database][to][:pass]} #{config[:database][to][:name]} < /tmp/#{tempfile}"
      if to == 'stage' || to == 'production'
        on to_host do |host|
          upload! "/tmp/#{tempfile}", "/tmp/#{tempfile}"
          within config[:ssh][to][:path] do
            execute :mysql, cmd
            execute :rm, "/tmp/#{tempfile}"
          end
        end
      else
        run "mysql " + cmd
      end

      # search replace imported database
      if to=="development"
        cmd = "wp search-replace '#{config[:url][from]}' '#{config[:url][to]}'"
      else
        cmd = config[:url][from]+' '+config[:url][to]
      end

      # network install
      if network
        cmd += " --network"
      end

      if to == 'stage' || to == 'production'
        cmd = 'thor wp:wp_cli:command -b="search-replace" -c="'+cmd+'" -e=' + to
      end
      run cmd

      # clean up
      run "rm /tmp/#{tempfile}"

    end

    desc "uploads [-f=prod -t=dev -e=folder1,folder2]", "Syncs uploads folder to[-t] and from[-f] environments (dev/stage/prod)."
    method_option :from, :type => :string, :aliases => "-f", :default => "production"
    method_option :to, :type => :string, :aliases => "-t", :default => "development"
    method_option :exclude, :type => :string, :aliases => "-e", :default => ""
    def uploads
      from = Wp::env_alt(options[:from])
      to = Wp::env_alt(options[:to])
      exclude = options[:exclude]

      unless exclude.empty?
        folders = exclude.split(",")
        exclude = folders.map { |f| "--exclude #{f}" }.join(" ")
        #say "Lets exclude '#{exclude}'", :green
        #exit
      end

      config = Wp::get_config

      say "Syncing uploads directory from #{from} to #{to}..."

      # set development directory
      config[:ssh][:development] = Hash.new
      config[:ssh][:development][:path] = Dir.pwd

      # Transfer via rsync
      # rsync -azh /local/path/file -e 'ssh -p 22334' user@host.com:/remote/path/file
      if to == "development"
        to_folder = "#{config[:ssh][to][:path]}/wp-content/uploads/".shellescape
        cmd = "rsync #{exclude} --iconv=utf-8-mac,utf-8 -avz --delete -e 'ssh -p #{config[:ssh][from][:port]}' #{config[:ssh][from][:user]}@#{config[:ssh][from][:server]}:#{config[:ssh][from][:path]}/wp-content/uploads/ #{to_folder}"
      else
        from_folder = "#{config[:ssh][from][:path]}/wp-content/uploads/".shellescape
        cmd = "rsync #{exclude} --iconv=utf-8-mac,utf-8 -avz --delete #{from_folder} -e 'ssh -p #{config[:ssh][to][:port]}' #{config[:ssh][to][:user]}@#{config[:ssh][to][:server]}:#{config[:ssh][to][:path]}/wp-content/uploads/"
      end
      if (from == 'stage' || from == 'production') && (to == 'stage' || to == 'production')
        cmd = "ssh -C -p#{config[:ssh][from][:port]} #{config[:ssh][from][:user]}@#{config[:ssh][from][:server]} \"#{cmd}\""
      end
      run cmd

    end
  end

  class Setup < Thor
    include Thor::Actions

    desc "db [-e=environment]" , "Create database if not exists in environment"
    method_option :environment, :type => :string, :aliases => "-e", :default => "stage"
    def db
      env = Wp::env_alt(options[:environment])
      config = Wp::get_config
      reverse_domain = config[:domain].split(".").reverse.join(".")

      # create database if not exists
      cmd = "mysql -u #{config[:database][env][:user]} -p#{config[:database][env][:pass]} -e 'create database if not exists #{config[:database][env][:name]};'"
      if env == "stage" || env == "production"
        cmd = "ssh -C -p#{config[:ssh][env][:port]} #{config[:ssh][env][:user]}@#{config[:ssh][env][:server]} \"#{cmd}\""
      end
      run cmd
    end

    desc "deploy [-e=stage]", "Setup environment for deployment"
    method_option :environment, :type => :string, :aliases => "-e", :default => "stage"
    def deploy
      env = Wp::env_alt(options[:environment])
      config = Wp::get_config
      if !(env == "stage" || env == "production")
        say "Environment must be stage or production"
        exit
      end
      reverse_domain = config[:domain].split(".").reverse.join(".")

      # setup files
      run "ssh -p#{config[:ssh][env][:port]} #{config[:ssh][env][:user]}@#{config[:ssh][env][:server]} 'mkdir #{config[:ssh][env][:path]} && cd #{config[:ssh][env][:path]} && git clone #{config[:git]} .'"

      # create database if not exists
      run "thor wp:setup:db -e=#{env}"
    end

  end

  class Deploy < Thor
    include Thor::Actions
    include SSHKit::DSL

    default_task :site

    desc "site [-e=stage] [-t=origin/master]", "Deploy site to stage or production"
    method_option :environment, :type => :string, :aliases => "-e", :default => "stage"
    method_option :target, :type => :string, :aliases => "-t", :default => "origin/master"
    def site
      t1 = Time.now
      env = Wp::env_alt(options[:environment])
      target = options[:target]
      config = Wp::get_config
      if !(env == "stage" || env == "production")
        say "Environment must be stage or production"
        exit
      end
      reverse_domain = config[:domain].split(".").reverse.join(".")

      if config[:ssh][env].has_key?(:path)
        path = config[:ssh][env][:path] + '/'
      else
        say "Path must be set in config file"
        exit
      end

      host = SSHKit::Host.new({
        hostname: config[:ssh][env][:server],
        port: config[:ssh][env][:port],
        user: config[:ssh][env][:user]
      })

      SSHKit.config.command_map[:git] = "/usr/bin/git"
      SSHKit.config.command_map[:bash] = "sudo /bin/bash"
      SSHKit.config.command_map[:wp] = "/usr/bin/wp"

      on host do |host|
        within config[:ssh][env][:path] do
          #puts execute :git, "fetch --all"
          execute :git, "fetch --all"
          execute :bash, "/usr/local/sbin/fixperms.sh #{config[:ssh][env][:path]}"
          execute :git, "checkout #{target}"

          # make site visible if blog_public is true or doesn't exist
          if env == "production"
            if not config.has_key?(:blog_public) or config[:blog_public]
              execute :wp, "option update blog_public 1"
            elsif config[:blog_public] == false
              execute :wp, "option update blog_public 0"
            end
          end

          # Always private on stage
          if env == "stage"
            execute :wp, "option update blog_public 0"
          end

        end
      end



      t2 = Time.now
      elapsed = (t2 - t1)

      # notification services
      if env == "production"
        # commit description
          f = open("|git log -1 --pretty=%h\\|%an\\|%B | cat - |head -3")
          git_info = f.read.strip
          revision,user,description = git_info.split("|")

        # new relic
        if config.has_key?(:new_relic)
          new_relic_key = config[:new_relic][:key]
          app_id = config[:new_relic][:app_id]
          if new_relic_key and app_id
            run_locally do
              execute "curl", '-H "x-api-key:'+new_relic_key+'" -d "deployment[application_id]='+app_id.to_s+'" -d "deployment[revision]='+revision+'" -d "deployment[description]='+description+'" -d "deployment[user]='+user+'" https://api.newrelic.com/deployments.xml'
            end
          end
        end

        # slack
        if config.has_key?(:slack)
          url = config[:slack][:url]
          channel = config[:slack][:channel]
          if url and channel
            message = "Revision #{revision} of " \
                      "#{config[:title]} deployed to #{env} by #{user} " \
                      "in #{sprintf('%5.3f seconds', elapsed)}."
            run_locally do
              execute "curl", "-X POST --data-urlencode 'payload={\"text\": \"#{message}\", \"channel\": \"##{channel}\", \"username\": \"mediebruket-bot\"}' #{url}"
            end
            #cmd = "curl -X POST --data-urlencode 'payload={\"text\": \"#{message}\", \"channel\": \"##{channel}\", \"username\": \"mediebruket-bot\"}' #{url}"
            #run cmd
          end

        end

      end
    end
  end

  class Generate < Thor
    include Thor::Actions

    default_task :config

    desc "config [--dir=.] [--force]", "Generates the config file used for deployment (default)"
    method_option :force, :type => :boolean
    method_option :dir, :type => :string, :default => "."
    def config
      destination = options[:dir] + "/config.yaml"
      FileUtils.rm(destination) if options[:force] && File.exist?(destination)
      if File.exist?(destination)
        say "Skipping #{destination} because it already exists", :yellow
      else
        wp_dir = options[:dir]
        config = open("https://github.com/mediebruket/thor-wordpress/raw/master/SAMPLE.config.yaml") { |f| f.read }

        # write file
        create_file destination, config
      end
    end

    desc "gitignore [--dir=.]", "Generate .gitignore"
    method_option :dir, :type => :string, :default => "."
    def gitignore
      wp_dir = options[:dir]
      destination = wp_dir + "/.gitignore"
      gitignore = open("https://github.com/mediebruket/thor-wordpress/raw/master/SAMPLE.gitignore") { |f| f.read }

      # write file
      create_file destination, gitignore
    end

    desc "new_relic [--dir=.]", "Generate new_relic.php"
    method_option :dir, :type => :string, :default => "."
    def new_relic
      wp_dir = options[:dir]
      destination = wp_dir + "/wp-content/mu-plugins/new_relic.php"
      new_relic = open("https://github.com/mediebruket/thor-wordpress/raw/master/SAMPLE.new_relic.php") { |f| f.read }

      # write file
      create_file destination, new_relic
    end

    desc "wp_config [--dir=.]", "Generate wp-config.php"
    method_option :dir, :type => :string, :default => "."
    def wp_config
      wp_dir = options[:dir]
      destination = wp_dir + "/wp-config.php"
      wp_config = open("https://github.com/mediebruket/thor-wordpress/raw/master/SAMPLE.wp-config.php") { |f| f.read }

      # random salts
      wp_config = wp_config.gsub!(/put_your_unique_phrase_here/) { |m| SecureRandom.urlsafe_base64(64) }

      # write file
      create_file destination, wp_config
    end

    desc "local_config [-e=dev]", "Generate local-config.php"
    method_option :environment, :type => :string, :aliases => "-e", :default => "dev"
    def local_config
      env = Wp::env_alt(options[:environment])
      config = Wp::get_config
      destination = "local-config.php"

      local_config = open("https://github.com/mediebruket/thor-wordpress/raw/master/SAMPLE.local-config.php") { |f| f.read }

      # replace strings
      local_config.gsub!(/dbname/, config[:database][env][:name])
      local_config.gsub!(/dbuser/, config[:database][env][:user])
      local_config.gsub!(/dbpassword/, config[:database][env][:pass])
      if env == "development"
        local_config.gsub!(/dbhost/, "localhost:/tmp/mysql.sock")
      else
        local_config.gsub!(/dbhost/, "localhost")
        destination = "local-config-remote.php"
      end

      # write file
      create_file destination, local_config

      # upload to remote
      if env != "development"
        to_host = SSHKit::Host.new({hostname: config[:ssh][env][:server],
                                  port: config[:ssh][env][:port],
                                  user: config[:ssh][env][:user]})
        on to_host do |host|
          upload! destination, "#{config[:ssh][env][:path]}/local-config.php"
        end
        FileUtils.rm(destination)
      end

    end

    desc "password", "Generates random password"
    def password
      say SecureRandom.urlsafe_base64(64)
    end

    method_options :dir => :string, :default => "."
    desc "wp_cli [--dir=.]", "Generates the config file used for wp-cli"
    def wp_cli
      dir = options["dir"]
      destination = "#{dir}/wp-cli.yml"
      create_config = true
      if File.exists?(destination)
        overwrite = ask "#{destination} already exists. Overwrite? y/n: ", :yellow
        if overwrite == "n"
          create_config = false
        elsif overwrite == "y"
          create_config = true
        end
      end

      if create_config
        config = {
          'path' => '.',
          'url' => 'http://sites/' + dir
        }
        create_file destination, config.to_yaml
      else
        say "Skipping #{destination} because it already exists"
      end
    end
  end
end

module Jekyll
  class Deploy < Thor
    include Thor::Actions
    include SSHKit::DSL
    default_task :site

    desc "site [-e]", "Deploy site to stage or production (default)"
    method_option :environment, :type => :string, :aliases => "-e", :default => "prod"
    def site
      SSHKit.config.command_map[:bash] = "sudo /bin/bash"
      t1 = Time.now
      env = Wp::env_alt(options[:environment])
      target = options[:target]
      config = Wp::get_config
      if !(env == "stage" || env == "production")
        say "Environment must be stage or production"
        exit
      end
      if config[:ssh][env].has_key?(:path)
        path = config[:ssh][env][:path] + '/'
      else
        say "Path must be set in config file"
        exit
      end

      cmd = "rsync -az -e \"ssh -p#{config[:ssh][env][:port]}\" _site/ #{config[:ssh][env][:user]}@#{config[:ssh][env][:server]}:#{config[:ssh][env][:path]}"
      #puts cmd
      run cmd

      # fix permissions
      host = SSHKit::Host.new({
        hostname: config[:ssh][env][:server],
        port: config[:ssh][env][:port],
        user: config[:ssh][env][:user]
      })
      on host do |host|
        within config[:ssh][env][:path] do
          execute :bash, "/usr/local/sbin/fixperms.sh #{config[:ssh][env][:path]}"
        end
      end

    end
  end

  class Setup < Thor
    include Thor::Actions
    default_task :deploy

    desc "deploy [-e]", "Setup environment for deployment (default)"
    method_option :environment, :type => :string, :aliases => "-e"
    def deploy
      env = options[:environment]
      if env == ""
        say "Missing environment [-e] parameter"
        exit
      end
      if !(env == "stage" || env == "production")
        say "Environment must be stage or production"
        exit
      end

      config = Wp::get_config
      reverse_domain = config[:domain].split(".").reverse.join(".")

      # setup files
      run "ssh -p#{config[:ssh][env][:port]} #{config[:ssh][env][:user]}@#{config[:ssh][env][:server]} 'mkdir -p #{config[:ssh][env][:path]} && cd #{config[:ssh][env][:path]} && git clone #{config[:git]} .'"

    end

  end

end

module Login
  class Ssh < Thor
    include Thor::Actions
    @@config_file = 'config.yaml'

    default_task :stage

    def self.get_config
      path = Pathname(Dir.pwd + '/' + @@config_file)
      if path.exist?
        return YAML::load(File.open(path.to_s)).with_indifferent_access
      else
        p "Missing config.yaml"
        abort
      end
    end

    def self.get_server_settings(server)
      settings = Ssh.get_config[:ssh][server]
      user = settings[:user]
      server = settings[:server]
      port = settings[:port]
      "#{user}@#{server} -p#{port}"

    end

    desc "stage", "Login to stage (default)"
    def stage
      login = Ssh.get_server_settings(:stage)
      run "ssh #{login}"
    end

    desc "prod", "Login to production"
    def prod
      login = Ssh.get_server_settings(:production)
      run "ssh #{login}"
    end

  end
end
