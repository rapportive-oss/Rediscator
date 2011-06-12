require 'thor'

require File.join(File.dirname(__FILE__), 'util')

module Rediscator
  class App < Thor
    namespace :rediscator

    include Thor::Actions
    include Util

    REQUIRED_PACKAGES = %w(
      git-core
      build-essential
      tcl8.5
      pwgen
      s3cmd
      openjdk-6-jre-headless
      unzip
      postfix
    )

    OPENJDK_JAVA_HOME = '/usr/lib/jvm/java-6-openjdk'

    REDIS_USER = 'redis'
    REDIS_REPO = 'https://github.com/antirez/redis.git'
    REDIS_LOG = '/var/log/redis.log'

    CLOUDWATCH_USER = 'cloudwatch'
    CLOUDWATCH_TOOLS_ZIP = 'CloudWatch-2010-08-01.zip'
    CLOUDWATCH_TOOLS_URL = "http://ec2-downloads.s3.amazonaws.com/#{CLOUDWATCH_TOOLS_ZIP}"

    REDIS_CONFIG_SUBSTITUTIONS = {
      /^daemonize .*$/ => 'daemonize no', # since we're using upstart to run it
      /^pidfile .*$/ => 'pidfile [REDIS_PATH]/tmp/redis.pid',
      /^loglevel .*$/ => 'loglevel notice',
      /^logfile .*$/ => 'logfile stdout',
      /^# syslog-enabled .*$/ => 'syslog-enabled yes',
      /^# syslog-ident .*$/ => "syslog-ident redis",
      /^dir .*$/ => 'dir [REDIS_PATH]',
      /^# requirepass .*$/ => 'requirepass [REDIS_PASSWORD]',
    }

    desc 'setup', 'Set up Redis'
    method_option :machine_name, :default => `hostname`.strip, :desc => "Name identifying this Redis machine"
    method_option :machine_role, :default => 'redis', :desc => "Description of this machine's role"
    method_option :admin_email, :required => true, :desc => "Email address to receive admin messages"
    method_option :ec2, :default => false, :type => :boolean, :desc => "Whether this instance is on EC2"
    method_option :remote_syslog, :desc => "Remote syslog endpoint to send all logs to"
    method_option :cloudwatch_namespace, :default => `hostname`.strip, :desc => "Namespace for CloudWatch metrics"
    method_option :sns_topic, :desc => "Simple Notification Service topic ARN for alarm notifications"
    method_option :redis_version, :required => true, :desc => "Version of Redis to install"
    method_option :run_tests, :default => false, :type => :boolean, :desc => "Whether to run the Redis test suite"
    method_option :backup_tempdir, :default => '/tmp', :desc => "Temporary directory for daily backups"
    method_option :backup_s3_prefix, :required => true, :desc => "S3 bucket and prefix for daily backups, e.g. s3://backups/redis"
    method_option :aws_access_key, :required => true, :desc => "AWS access key ID for backups and monitoring"
    method_option :aws_secret_key, :required => true, :desc => "AWS secret access key for backups and monitoring"
    def setup
      unless options[:machine_name] =~ /\w+\.\w+$/
        raise ArgumentError, "--machine-name should be a FQDN or Postfix will break :("
      end
      redis_version = options[:redis_version]
      run_tests = options[:run_tests]
      backup_tempdir = options[:backup_tempdir]
      backup_s3_prefix = options[:backup_s3_prefix]
      aws_access_key = options[:aws_access_key]
      aws_secret_key = options[:aws_secret_key]

      rediscator_path = File.join(Dir.pwd, File.dirname(__FILE__), '..', '..')

      setup_properties = {
        :MACHINE_NAME => options[:machine_name],
        :ADMIN_EMAIL => options[:admin_email],
        :REDIS_VERSION => redis_version,
      }

      sudo! 'apt-get', :update
      postfix_debconf = apply_substitutions(File.read("#{rediscator_path}/etc/postfix.debconf"), setup_properties)
      sudo! 'debconf-set-selections', :stdin => postfix_debconf
      package_install! *REQUIRED_PACKAGES

      as :root do
        warn_stopped_upstart = apply_substitutions(File.read("#{rediscator_path}/etc/redis-warn-stopped.upstart"), setup_properties)
        create_file! '/etc/init/warn-stopped.conf', warn_stopped_upstart

        create_file! '/etc/rsyslog.d/60-remote-syslog.conf', <<-RSYSLOG if options[:remote_syslog]
*.*                                     @#{options[:remote_syslog]}
        RSYSLOG

        create_file! '/etc/rsyslog.d/99-redis.conf', <<-RSYSLOG
:programname, isequal, "redis"          #{REDIS_LOG}
        RSYSLOG

        run! *%w(restart rsyslog)
        setup_properties[:REDIS_LOG] = REDIS_LOG

        create_file! '/etc/logrotate.d/redis', <<-LOGROTATE
#{REDIS_LOG} {
        weekly
        missingok
        rotate 20
        compress
        delaycompress
        notifempty
        postrotate
          reload rsyslog >/dev/null 2>&1 || true
        endscript
}
        LOGROTATE
      end

      unless user_exists?(REDIS_USER)
        sudo! *%W(adduser --disabled-login --gecos Redis,,, #{REDIS_USER})
      end
      setup_properties[:REDIS_USER] = REDIS_USER

      as REDIS_USER do
        inside "~#{REDIS_USER}" do
          create_file! '.forward', 'root'

          run! *%w(mkdir -p opt)
          inside 'opt' do
            unless File.exists?('redis')
              run! :git, :clone, REDIS_REPO
            end
            inside 'redis' do
              unless git_branch_exists? redis_version
                run! :git, :checkout, '-b', redis_version, redis_version
              end
              run! :make
              run! :make, :test if run_tests
            end

            run! *%W(mkdir -p redis-#{redis_version})

            inside "redis-#{redis_version}" do
              run! *%w(mkdir -p bin etc tmp)

              setup_properties[:REDIS_PATH] = Dir.pwd
              setup_properties[:REDIS_PASSWORD] = run!(*%w(pwgen --capitalize --numerals --symbols 16 1)).strip

              as :root do
                redis_upstart = apply_substitutions(File.read("#{rediscator_path}/etc/redis.upstart"), setup_properties)
                create_file! '/etc/init/redis.conf', redis_upstart

                if run!(*%w(status redis)).strip =~ %r{ start/running\b}
                  run! *%w(stop redis)
                end
              end

              %w(server cli).each do |thing|
                run! *%W(cp ../redis/src/redis-#{thing} bin)
              end

              config_substitutions = REDIS_CONFIG_SUBSTITUTIONS.map do |pattern, replacement|
                [pattern, apply_substitutions(replacement, setup_properties)]
              end

              default_conf = File.read('../redis/redis.conf')
              substituted_conf = apply_substitutions(default_conf, config_substitutions)

              create_file! 'etc/redis.conf', substituted_conf, :permissions => '640'
            end
          end

          sudo! *%w(start redis)

          sleep 1
          run! "#{setup_properties[:REDIS_PATH]}/bin/redis-cli", '-a', setup_properties[:REDIS_PASSWORD], :ping, :echo => false

          run! *%w(mkdir -p bin)

          create_file! 'bin/redispw', <<-SH, :permissions => '755'
#!/bin/sh -e
grep ^requirepass #{setup_properties[:REDIS_PATH]}/etc/redis.conf | cut -d' ' -f2
          SH

          create_file! 'bin/authed-redis-cli', <<-SH, :permissions => '755'
#!/bin/sh -e
exec #{setup_properties[:REDIS_PATH]}/bin/redis-cli -a "$($(dirname $0)/redispw)" "$@"
          SH

          setup_properties[:REDIS_VERSION] = run!('bin/authed-redis-cli', :info).
            split("\n").
            map {|line| line.split(':', 2) }.
            detect {|property, value| property == 'redis_version' }[1]

          run! *%W(cp #{rediscator_path}/bin/s3_gzbackup bin)

          sudo! :mkdir, '-p', backup_tempdir
          sudo! :chmod, 'a+rwxt', backup_tempdir

          create_file! '.s3cfg', <<-S3CFG, :permissions => '600'
[default]
access_key = #{aws_access_key}
secret_key = #{aws_secret_key}
          S3CFG

          backup_command = %W(
            ~#{REDIS_USER}/bin/s3_gzbackup
            --temp-dir='#{backup_tempdir}'
            #{setup_properties[:REDIS_PATH]}/dump.rdb
            '#{backup_s3_prefix}'
          ).join(' ')

          # make sure dump.rdb exists so the backup job doesn't fail
          run! "#{setup_properties[:REDIS_PATH]}/bin/redis-cli", '-a', setup_properties[:REDIS_PASSWORD], :save, :echo => false

          ensure_crontab_entry! backup_command, :hour => '03', :minute => '42'
        end
      end


      unless user_exists?(CLOUDWATCH_USER)
        sudo! *%W(adduser --disabled-login --gecos Amazon\ Cloudwatch\ monitor,,, #{CLOUDWATCH_USER})
      end
      setup_properties[:CLOUDWATCH_USER] = CLOUDWATCH_USER

      as CLOUDWATCH_USER do
        inside "~#{CLOUDWATCH_USER}" do
          home = Dir.pwd

          create_file! '.forward', 'root'

          run! *%w(mkdir -p opt)
          cloudwatch_dir = nil
          inside 'opt' do
            if Dir.glob('CloudWatch-*/bin/mon-put-data').empty?
              run! :wget, '-q', CLOUDWATCH_TOOLS_URL unless File.exists? CLOUDWATCH_TOOLS_ZIP
              run! :unzip, CLOUDWATCH_TOOLS_ZIP
            end
            cloudwatch_dirs = Dir.glob('CloudWatch-*').select {|dir| File.directory? dir }
            case cloudwatch_dirs.size
            when 1; cloudwatch_dir = cloudwatch_dirs[0]
            when 0; raise 'Failed to install CloudWatch tools!'
            else; raise 'Multiple versions of CloudWatch tools installed; confused.'
            end
          end
          setup_properties[:CLOUDWATCH_TOOLS_PATH] = "#{home}/opt/#{cloudwatch_dir}"

          aws_credentials_path = "#{home}/.aws-credentials"
          create_file! aws_credentials_path, <<-CREDS, :permissions => '600'
AWSAccessKeyId=#{aws_access_key}
AWSSecretKey=#{aws_secret_key}
          CREDS

          ensure_sudoers_entry! :who => CLOUDWATCH_USER,
                                :as_who => REDIS_USER,
                                :nopasswd => true,
                                :command => "/home/#{REDIS_USER}/bin/authed-redis-cli INFO",
                                :comment => "Allow #{CLOUDWATCH_USER} to gather Redis metrics, but not do anything else to Redis"

          run! *%w(mkdir -p bin)

          env_vars = [
            [:JAVA_HOME, OPENJDK_JAVA_HOME],
            [:AWS_CLOUDWATCH_HOME, setup_properties[:CLOUDWATCH_TOOLS_PATH]],
            [:PATH, %w($PATH $AWS_CLOUDWATCH_HOME/bin).join(':')],
            [:AWS_CREDENTIAL_FILE, aws_credentials_path],
          ]
          env_vars_script = (%w(#!/bin/sh) + env_vars.map do |var, value|
            "#{var}=#{value}; export #{var}"
          end).join("\n")
          setup_time_env_vars = env_vars.map do |var, value|
            # run! doesn't expand $SHELL_VARIABLES, so we have to do it.
            expanded = value.
              gsub('$PATH', ENV['PATH']).
              gsub('$AWS_CLOUDWATCH_HOME', setup_properties[:CLOUDWATCH_TOOLS_PATH])
            [var, expanded]
          end

          cloudwatch_env_vars_path = "#{home}/bin/aws-cloudwatch-env-vars.sh"
          create_file! cloudwatch_env_vars_path, env_vars_script, :permissions => '+rwx'

          metric_script = <<-BASH
#!/bin/bash -e
export PATH=$PATH:$HOME/bin
. aws-cloudwatch-env-vars.sh

          BASH

          setup_properties[:CLOUDWATCH_NAMESPACE] = options[:cloudwatch_namespace]
          custom_metric_dimensions = {
            :MachineName => options[:machine_name],
            :MachineRole => options[:machine_role],
          }
          builtin_metric_dimensions = {}
          if options[:ec2]
            instance_id = system!(*%w(curl -s http://169.254.169.254/latest/meta-data/instance-id)).strip
            custom_metric_dimensions[:InstanceId] = builtin_metric_dimensions[:InstanceId] = instance_id
          end
          setup_properties[:CLOUDWATCH_DIMENSIONS] = cloudwatch_dimensions(custom_metric_dimensions)

          shared_alarm_options = {
            :cloudwatch_tools_path => setup_properties[:CLOUDWATCH_TOOLS_PATH],
            :env_vars => setup_time_env_vars,

            :dimensions => custom_metric_dimensions,
          }
          if options[:sns_topic]
            topic = options[:sns_topic]
            setup_properties[:SNS_TOPIC] = topic
            shared_alarm_options.merge!({
              :actions_enabled => true,
              :ok_actions => topic,
              :alarm_actions => topic,
              :insufficient_data_actions => topic,
            })
          else
            setup_properties[:SNS_TOPIC] = "<WARNING: No SNS topic specified.  You will not get notified of alarm states.>"
          end

          metrics = [
            # friendly                metric-name               script                  script-args                  unit       check
            ['Free RAM',              :FreeRAMPercent,          'free-ram-percent.sh',  [],                          :Percent,  [:<,      20]],
            ['Free Disk',             :FreeDiskPercent,         'free-disk-percent.sh', [],                          :Percent,  [:<,      20]],
            ['Load Average (1min)',   :LoadAvg1Min,             'load-avg.sh',          [1],                         :Count,    nil          ],
            ['Load Average (15min)',  :LoadAvg15Min,            'load-avg.sh',          [3],                         :Count,    [:>,     1.0]],
            ['Redis Blocked Clients', :RedisBlockedClients,     'redis-metric.sh',      %w(blocked_clients),         :Count,    [:>,       5]],
            ['Redis Used Memory',     :RedisUsedMemory,         'redis-metric.sh',      %w(used_memory),             :Bytes,    nil          ],
            ['Redis Unsaved Changes', :RedisUnsavedChanges,     'redis-metric.sh',      %w(changes_since_last_save), :Count,    [:>, 300_000]],
          ]

          if options[:ec2]
            metrics << ['CPU Usage', 'AWS/EC2:CPUUtilization',  nil,                    [],                  :Percent,  [:>,  90]]
          end

          metric_scripts = metrics.map {|_, _, script, _, _, _| "#{rediscator_path}/bin/#{script}" if script }.compact.uniq
          run! :cp, *(metric_scripts + [:bin])
          metrics.each do |friendly, metric, script, args, unit, (comparison, threshold)|
            namespace_or_metric, metric_or_nil = metric.to_s.split(':', 2)
            if metric_or_nil
              namespace = namespace_or_metric
              metric = metric_or_nil
              dimensions = builtin_metric_dimensions
            else
              namespace = options[:cloudwatch_namespace]
              metric = namespace_or_metric
              dimensions = custom_metric_dimensions
            end

            if script
              metric_script << %W(
                mon-put-data
                --metric-name '#{metric}'
                --namespace '#{namespace}'
                --dimensions '#{cloudwatch_dimensions(dimensions)}'
                --unit '#{unit}'
                --value "$(#{script} #{args.map {|arg| "'#{arg}'" }.join(' ')})"
              ).join(' ') << "\n"
            end

            if comparison
              symptom = case comparison
                        when :>, :>=; 'high'
                        when :<, :<=; 'low'
                        end
              alarm_options = shared_alarm_options.merge({
                :alarm_name => "#{options[:machine_name]}: #{friendly}",
                :alarm_description => "Alerts if #{options[:machine_role]} machine #{options[:machine_name]} has #{symptom} #{friendly}.",

                :namespace => namespace,
                :metric_name => metric,
                :dimensions => dimensions,

                :comparison_operator => comparison,
                :threshold => threshold,
                :unit => unit,
              })

              setup_cloudwatch_alarm! alarm_options
            end
          end

          create_file! 'bin/log-cloudwatch-metrics.sh', metric_script, :permissions => '+rwx'

          monitor_command = "$HOME/bin/log-cloudwatch-metrics.sh"
          ensure_crontab_entry! monitor_command, :minute => '*/2'
        end
      end

      puts "Properties:"
      setup_properties.each do |property, value|
        puts "\t#{property}:\t#{value}"
      end
    end
  end
end
