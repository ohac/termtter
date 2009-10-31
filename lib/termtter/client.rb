# -*- coding: utf-8 -*-
require 'fileutils'
require 'logger'
require 'termcolor'

module Termtter
  class CommandNotFound < StandardError; end
  class CommandCanceled < StandardError; end

  module Client

    @hooks = {}
    @commands = {}
    @filters = []
    @since_id = nil
    @task_manager = Termtter::TaskManager.new

    config.set_default(:logger, nil)
    config.set_default(:update_interval, 120)
    config.set_default(:prompt, '> ')
    config.set_default(:devel, false)

    Thread.abort_on_exception = true

    class << self

      attr_reader :commands, :hooks

      # plug :: Name -> (Hash) -> IO () where NAME = String | Symbol | [NAME]
      def plug(name, options = {})
        if Array === name # Obviously `name.respond_to?(:each)` is better, but for 1.8.6 compatibility we cannot.
          name.each {|i| plug(i, options) }
          return
        end
        options.each do |key, value|
          config.plugins.__refer__(name.gsub(/-/, '_').to_sym).__assign__(key.to_sym, value)
        end
        load "plugins/#{name}.rb"
      rescue Exception => e
        Termtter::Client.handle_error(e)
      end

      def public_storage
        @public_storage ||= {}
      end

      def add_filter(&b)
        warn "add_filter method will be removed. Use Termtter::Client.register_hook(:name => ..., :point => :filter_for_output, :exec => ... ) instead."
        @filters << b
      end

      def clear_filter
        @filters.clear
      end

      def register_hook(arg, opts = {}, &block)
        hook = case arg
          when Hook
            arg
          when Hash
            Hook.new(arg)
          when String, Symbol
            options = { :name => arg }
            options.merge!(opts)
            options[:exec_proc] = block
            Hook.new(options)
          else
            raise ArgumentError, 'must be given Termtter::Hook, Hash, String or Symbol'
          end
        @hooks[hook.name] = hook
      end

      def get_hook(name)
        @hooks[name]
      end

      def get_hooks(point)
        # TODO: sort by alphabet
        @hooks.values.select do |hook|
          hook.match?(point)
        end
      end

      def register_command(arg, opts = {}, &block)
        command = case arg
          when Command
            arg
          when Hash
            Command.new(arg)
          when String, Symbol
            options = { :name => arg }
            options.merge!(opts)
            options[:exec_proc] = block
            Command.new(options)
          else
            raise ArgumentError, 'must be given Termtter::Command, Hash or String(Symbol) with block'
          end
        @commands[command.name] = command
      end

      def add_command(name)
        if block_given?
          command = Command.new(:name => name)
          yield command
          @commands[command.name] = command
        else
          raise ArgumentError, 'must be given block to set parameters'
        end
      end

      def clear_command
        @commands.clear
      end

      def get_command(name)
        @commands[name]
      end

      def register_macro(name, macro, options = {})
        command = {
          :name => name.to_sym,
          :exec_proc => lambda {|arg| call_commands(macro % arg)}
        }.merge(options)
        register_command(command)
      end

      # statuses => [status, status, ...]
      # status => {
      #             :id => status id,
      #             :created_at => created time,
      #             :user_id => user id,
      #             :name => user name,
      #             :screen_name => user screen_name,
      #             :source => source,
      #             :reply_to => reply_to status id,
      #             :text => status,
      #             :original_data => original data,
      #           }
      def output(statuses, event)
        return if statuses.nil? || statuses.empty?

        statuses = statuses.sort_by(&:id)
        call_hooks(:pre_filter, statuses, event)

        filtered = apply_filters_for_hook(:filter_for_output, statuses.map(&:clone), event)

        @filters.each do |f|  # TODO: code for compatibility. delete someday.
          filtered = f.call(filtered, event)
        end

        call_hooks(:post_filter, filtered, event)
        get_hooks(:output).each do |hook|
          hook.call(
            apply_filters_for_hook("filter_for_#{hook.name}", filtered, event),
            event
          )
        end
      end

      def apply_filters_for_hook(hook_name, statuses, event)
        get_hooks(hook_name).inject(statuses) {|s, hook|
          hook.call(s, event)
        }
      end

      # return last hook return value
      def call_hooks(point, *args)
        result = nil
        get_hooks(point).each {|hook|
          break if result == false # interrupt if hook return false
          result = hook.call(*args)
        }
        result
      end

      def call_commands(text)
        @task_manager.invoke_and_wait do
          # FIXME: This block can become Maybe Monad
          get_hooks("pre_command").each {|hook|
            break if text == nil # interrupt if hook returns nil
            text = hook.call(text)
          }
          return if text.empty?

          commands = find_commands(text)
          raise CommandNotFound, text if commands.empty?

          commands.each do |command|
            command_str, command_arg = Command.split_command_line(text)

            modified_arg = command_arg
            # FIXME: This block can become Maybe Monad
            get_hooks("modify_arg_for_#{command.name.to_s}").each {|hook|
              break if modified_arg == false # interrupt if hook return false
              modified_arg = hook.call(command_str, modified_arg)
            }

            begin
              call_hooks("pre_exec_#{command.name.to_s}", command, modified_arg)
              result = command.call(command_str, modified_arg, text) # exec command
              call_hooks("post_exec_#{command.name.to_s}", command_str, modified_arg, result)
            rescue CommandCanceled
            end
          end
          call_hooks("post_command", text)
        end
      end

      def command_exists?(text)
        @commands.values.any? {|command| command.match?(text) }
      end

      def find_commands(text)
        @commands.values.select {|command| command.match?(text) }
      end

      def pause
        @task_manager.pause
      end

      def resume
        @task_manager.resume
      end

      def add_task(*arg, &block)
        @task_manager.add_task(*arg, &block)
      end

      def exit
        puts 'finalizing...'
        call_hooks(:exit)
        @task_manager.kill
      end

      def load_config
        legacy_config_support() if File.exist? Termtter::CONF_DIR
        unless File.exist?(Termtter::CONF_FILE)
          require 'termtter/config_setup'
          ConfigSetup.run
        end
        load Termtter::CONF_FILE
      end

      def legacy_config_support
        case File.ftype(File.expand_path('~/.termtter'))
        when 'directory'
          # nop
        when 'file'
          move_legacy_config_file
        end
      end

      def move_legacy_config_file
        FileUtils.mv(
          Termtter::CONF_DIR,
          File.expand_path('~/.termtter___'))
        Dir.mkdir(Termtter::CONF_DIR)
        FileUtils.mv(
          File.expand_path('~/.termtter___'),
          Termtter::CONF_FILE)
      end

      def logger
        @logger
      end

      def setup_logger
        @logger = config.logger || default_logger
      end

      def default_logger
        logger = Logger.new(STDOUT)
        logger.formatter = lambda {|severity, time, progname, message|
          color =
            case severity
            when /^DEBUG/
              'blue'
            when /^INFO/
              'cyan'
            when /^WARN/
              'magenta'
            when /^ERROR/
              'red'
            when /^FATAL/
              'on_red'
            else
              'white'
            end
          TermColor.parse("<#{color}>" + TermColor.escape("[#{severity}] #{message}\n") + "</#{color}>")
        }
        logger
      end

      def init(&block)
        @init_block = block
      end

      def load_plugins
        plug 'defaults'
        plug config.system.load_plugins
      end

      def eval_init_block
        @init_block.call(self) if @init_block
      end

      def run
        load_config()
        load_plugins()
        Termtter::API.setup()
        setup_logger()
        eval_init_block()

        config.system.eval_scripts.each do |script|
          begin
            eval script
          rescue Exception => e
            handle_error(e)
          end
        end

        config.system.run_commands.each {|cmd| call_commands(cmd) }

        unless config.system.cmd_mode
          @task_manager.run()
          call_hooks(:initialize)
          call_hooks(:launched)
        end
      end

      def handle_error(e)
        if logger
          msg = e.message
          # TODO ad-hoc
          msg = msg.split[0] if msg.index('Twitter / Over capacity')
          logger.error("#{e.class.to_s}: #{msg}")
          logger.error(e.backtrace.join("\n")) if config.devel
        else
          raise e
        end
        get_hooks(:on_error).each {|hook| hook.call(e) }
      rescue Exception => e
        puts "Error: #{e}"
        puts e.backtrace.join("\n")
      end

      def confirm(message, default_yes = true, &block)
        pause # TODO: TaskManager から呼ばれるならこれいらないなぁ

        prompt =
          if default_yes
            "\"#{message}".strip + "\" [Y/n] "
          else
            "\"#{message}".strip + "\" [N/y] "
          end
        readline = Readline.readline(prompt, false)
        result =
          if !!(/^$/ =~ readline) 
            default_yes
          else
            !!(/^y/i =~ readline)
          end

        if result && block
          block.call
        end

        result
      ensure
        resume # TODO: TaskManager から呼ばれるならこれいらないなぁ
      end
    end
  end
end
