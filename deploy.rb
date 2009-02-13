#############################################################
# Application
#############################################################

set :application, "t4s"
set :deploy_to, "/var/www/apps/#{application}"

#############################################################
# Apache VHost
#############################################################
set :apache_vhost_name, 't4s'

#############################################################
# General Settings
#############################################################

ssh_options[:paranoid] = false
default_run_options[:pty] = true
set :use_sudo, true

set :keep_releases, 15

#############################################################
# Servers
#############################################################

set :user, "wei"
set :domain, "173.45.230.198" #"staging.ruby.wested.org"
#set :url, "evaluationtoolkit.org"
server domain, :app, :web
role :db, domain, :primary => true

#############################################################
# Git Settings
#############################################################

# This will execute the Git revision parsing on the *remote* server rather than locally
set :real_revision, lambda { source.query_revision(revision) { |cmd| capture(cmd) } }
set :git_enable_submodules, true


set :github_username, `git config --global -l | grep github.user`.split('=')[1]

#############################################################
# Github
#############################################################

set :scm, :git
set :deploy_via, :remote_cache

set :repository, "git@github.com:wested/#{application}.git"

#############################################################
# Comment out the settings in the Github section and use
# these if for some reason the server can not resolve github
# This will deploy from your local copy of the repository -
# it may take a while...
#############################################################

# set :scm, :git
# set :deploy_via, :copy
# set :copy_cache, true
# set :repository, '.git'

#############################################################
# Set Ups for Various Deployment Environments
#############################################################

task :production do
  set :branch, "production"
  set :rails_env, "production"
  set :deploy_to, "/var/www/apps/#{application}"
  set :host, ""
end

task :staging do
  # set(:branch) do
  #   Capistrano::CLI.ui.ask "Set branch: "
  # end
  set(:branch) do
    current_branch = `git branch`.match(/\* (.*)/)[1]
    specified_branch = Capistrano::CLI.ui.ask "Branch [#{current_branch}]: "
    specified_branch == '' ? current_branch : specified_branch
  end
  set(:previous_branch) do
    if branch == 'i1'
      nil
    else
      "i#{branch.split(/[A-Za-z]/)[1].to_i - 1}"
    end
  end
  set :rails_env, "staging"
  set :deploy_to, "/var/www/apps/#{application}/#{branch}"
  set :host, "173.45.230.198"
  set :url, "#{branch}.#{application}.staging.ruby.wested.org"
  
  namespace :deploy do
    desc "Deploy a new iteration branch"
    task :cold do
      db_already_exists = create_db
      !db_already_exists ?  '' : clone_db
      create_database_yaml
      update
      migrate
      install_gems
      update_config
      passenger:enable_staging
      passenger:restart
      passenger:kickstart
      #tag_last_deploy
      notify
    end

    desc "Setup Apache 2 virtual host and log files for this branch"
    task :setup_apache_vhost do
      sudo "touch /var/log/apache2/#{branch}-#{application}-error.log"
      sudo "touch /var/log/apache2/#{branch}-#{application}-access.log"
      sudo 'chown -Rf root:adm /var/log/apache2'
      sudo 'chmod -R 640 /var/log/apache2'
    end
    
    desc "Creates Vhost Conf File for Project if it doesn't exits"
    task :create_proj_vhost_conf do
      proj_vhost = false
      run 'ls /etc/apache2/sites-available/' do |ch, stream, data|
        if stream == :out
          data.each do |line|
            if line == "#{application}"
              proj_vhost = true
            end
          end
        end
      end
      if !proj_vhost
        vhost <<-END
          <VirtualHost *>
            ServerName #{application}.staging.ruby.wested.org
            <Location />
              Order allow,deny
              Deny from all
            </Location>
          </VirtualHost>
        END
        put vhost, "/etc/apache2/sites-available/#{application}"
        sudo "a2ensite #{application}"
        passenger:restart_apache
      else
        puts "Project vhost conf already exists." and return false
      end
    end
    
    desc "Creates Vhost Conf File for branch if it doesn't exits"
    task :create_branch_vhost_conf do
      branch_vhost = false
      run 'ls /etc/apache2/sites-available/' do |ch, stream, data|
        if stream == :out
          data.each do |line|
            if line == "#{application}-#{branch}-staging"
              branch_vhost = true
            end
          end
        end
      end
      if !branch_vhost
        vhost <<-END
          <VirtualHost *>
              ServerName #{branch}.#{application}.staging.ruby.wested.org
              DocumentRoot /var/www/apps/#{application}/#{branch}/current/public
              RailsEnv staging

              <Directory /var/www/apps/#{application}/#{branch}/current/public>
                      Options FollowSymLinks
                      AllowOverride None
                      Order allow,deny
                      allow from all
              </Directory>

              ErrorLog /var/log/apache2/#{application}-#{branch}-error.log
              CustomLog /var/log/apache2/#{application}-#{branch}-access.log common
          </VirtualHost>
        
          <VirtualHost *>
            ServerName #{branch}.#{application}.staging.ruby.wested.org
            <Location />
              Order allow,deny
              Deny from all
            </Location>
          </VirtualHost>
        END
        put vhost, "/etc/apache2/sites-available/#{application}-#{branch}-staging"
        sudo "a2ensite #{application}-#{branch}-staging"
        passenger:restart_apache
      else
        puts "Branch vhost conf already exists." and return false
      end
    end

    desc "Creates new database for the iteration branch"
    task :create_db do
      db_exists = false
      run "echo \"SELECT IF(EXISTS (SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '#{application}-#{branch}-staging'), true, false);\" | mysql -u root" do |ch, stream, data|
        if stream == :err
          abort "capured output on STDERR: #{data}"
        elsif stream == :out
          db_exists = data.split("\n")[1]
        end
      end
      
      if !db_exists
        run "mysqladmin -u root create #{application}-#{branch}-staging" and return true
      else  
        puts "On branch #{branch}, database already exists." and return false
      end
    end
    

    desc "Copies previous branch db and creates new db with the same data for the new iteration branch"
    task :clone_db do
      if !previous_branch.nil?
        previous_db_exists = false
        run "echo \"SELECT IF(EXISTS (SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '#{application}-#{previous_branch}-staging'), true, false);\" | mysql -u root" do |ch, stream, data|
          if stream == :err
            abort "capured output on STDERR: #{data}"
          elsif stream == :out
            previous_db_exists = data.split("\n")[1]
          end
        end
        if previous_db_exists
          run "mysqldump -u root --opt #{application}-#{previous_branch}-staging | mysql -u root #{application}-#{branch}-staging" and return true
        end
      else
        puts "On branch #{branch}, previous branch is nil, no database to clone." and return false
      end
    end

    desc "Creates database.yml for new iteration"
    task :create_database_yaml do
      sudo "mkdir -p #{shared_path}/config"
      sudo "chown wei:wei #{shared_path}/config"
      db = {'staging' => {'adapter' => 'mysql', 'encoding' => 'utf8', 'database' => "#{application}-#{branch}-staging", 'username' => 'root', 'password' => ''}}
      put db.to_yaml, "#{shared_path}/config/database.yml"
    end
  end

end

#############################################################
# Symlinks for Static Files
#############################################################

namespace :deploy do
	desc "Set Symlinks for Static Files (like database.yml)"
	task :update_config, :roles => [:app] do
		sudo "ln -sf #{shared_path}/config/database.yml #{release_path}/config/database.yml"
		sudo "ln -sf #{shared_path}/log #{release_path}/log"
	end	
end

#############################################################
# Install Missing Gems
#############################################################

namespace :deploy do
	desc "Install Missing Gems"
	task :install_gems, :roles => [:app] do
		run "cd #{release_path}; sudo /usr/bin/rake gems:install"
	end
end

#############################################################
# Tag Deployment
#############################################################

namespace :deploy do
  task :tag_last_deploy do
    # release_name is set internally by capistrano and is used to name the revision
    set :tag_name, "deployed_to_#{rails_env}_#{release_name}_#{github_username}"
    `git tag -a -m "Tagging deploy to #{rails_env} at #{release_name} by #{github_username}" #{tag_name} #{branch}`
    `git push --tags`
    puts "Tagged release with #{tag_name}."
  end
end

#############################################################
# Deployment Notification
#############################################################

namespace :deploy do
  task :notify do
    run "cd #{release_path}; rake RAILS_ENV=#{rails_env} send_deployment_notification -s revision=#{real_revision} host=#{host} rails_env=#{rails_env}"
  end
end

#############################################################
# Passenger
#############################################################

namespace :deploy do
  desc "Remove deploy:restart In Favor Of passenger:restart Task"
  task :restart do
  end
end

namespace :passenger do

  desc "Restart Application"
  task :restart do
    run "touch #{current_path}/tmp/restart.txt"
  end
  
  desc "Create an initial request so that Passenger is spinning for the first user"
  task :kickstart do
    run "curl -I http://www.#{url}"
  end

	desc "Set Environment to Development"
	task :development do
		sudo "a2dissite #{apache_vhost_name}-production"
		sudo "a2ensite #{apache_vhost_name}-development"
	end
	after "passenger:development", "passenger:restart_apache"
	
	desc "Set Environment to Production"
	task :production do
		sudo "a2dissite #{apache_vhost_name}-development"
		sudo "a2ensite #{apache_vhost_name}-production"
	end
	after "passenger:production", "passenger:restart_apache"
	
	desc "Enable Staging Environment"
	task :enable_staging do
	  sudo "a2ensite #{apache_vhost_name}-#{branch}-staging"
	end
	after "passenger:enable_staging", "passenger:restart_apache"
	
	desc "Restart Apache"
	task :restart_apache do 
		sudo "/etc/init.d/apache2 restart"
	end
	after "passenger:restart_apache", "passenger:restart"
	
	desc "Check Passenger Status"
	task :status do
	  sudo 'passenger-status'
	end
	
	desc "Check Apache/Passenger Memory Usage"
	task :memory_usage do
	  sudo 'passenger-memory-stats'
	end
end

#############################################################
# Run Order
#############################################################

# Do not change below unless you know what you are doing!
after "deploy:update_code",     "deploy:update_config"
after "deploy",                 "deploy:cleanup"
after "deploy:cleanup",         "deploy:install_gems"
after "deploy:install_gems",    "deploy:migrate"
after "deploy:migrate",         "passenger:restart"
after "passenger:restart",      "passenger:kickstart"
after "passenger:kickstart",    "deploy:tag_last_deploy"
#after "deploy:tag_last_deploy", "deploy:notify"