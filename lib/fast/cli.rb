# frozen_string_literal: true

require 'fast'
require 'fast/version'
require 'coderay'
require 'optparse'
require 'ostruct'

# Fast is a powerful tool to search through the command line for specific Ruby code.
# It defines #report and #highlight functions that can be used to pretty print
# code and results from the search.
module Fast
  module_function

  # Highligh some source code based on the node.
  # Useful for printing code with syntax highlight.
  def highlight(node, show_sexp: false)
    output =
      if node.respond_to?(:loc) && !show_sexp
        node.loc.expression.source
      else
        node
      end
    CodeRay.scan(output, :ruby).term
  end

  # Combines {.highlight} with files printing file name in the head with the
  # source line.
  # @param result [Astrolabe::Node]
  # @param show_sexp [Boolean] Show string expression instead of source
  # @param file [String] Show the file name and result line before content
  # @param headless [Boolean] Skip printing the file name and line before content
  # @example
  #   Fast.highlight(Fast.search(...))
  def report(result, show_sexp: false, file: nil, headless: false)
    if file
      line = result.loc.expression.line if result.is_a?(Parser::AST::Node)
      puts(highlight("# #{file}:#{line}")) unless headless
    end
    puts highlight(result, show_sexp: show_sexp)
  end

  # Command Line Interface for Fast
  class Cli # rubocop:disable Metrics/ClassLength
    attr_reader :pattern, :show_sexp, :pry, :from_code, :similar, :help
    def initialize(args)
      args = replace_args_with_shortcut(args) if args.first&.start_with?('.')

      @pattern, *@files = args.reject { |arg| arg.start_with? '-' }

      option_parser.parse! args

      @files = [*@files].reject { |arg| arg.start_with?('-') }
    end

    def option_parser # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      @option_parser ||= OptionParser.new do |opts| # rubocop:disable Metrics/BlockLength
        opts.banner = 'Usage: fast expression <files> [options]'
        opts.on('-d', '--debug', 'Debug fast engine') do
          @debug = true
        end

        opts.on('--ast', 'Print AST instead of code') do
          @show_sexp = true
        end

        opts.on('--captures', 'Print only captures of the patterns and skip node results') do
          @captures = true
        end

        opts.on('--headless', 'Print results without the file name in the header') do
          @headless = true
        end

        opts.on('--pry', 'Jump into a pry session with results') do
          @pry = true
          require 'pry'
        end

        opts.on('-c', '--code', 'Create a pattern from code example') do
          if @pattern
            @from_code = true
            @pattern = Fast.ast(@pattern).to_sexp
            debug 'Expression from AST:', @pattern
          end
        end

        opts.on('-s', '--similar', 'Search for similar code.') do
          @similar = true
          @pattern = Fast.expression_from(Fast.ast(@pattern))
          debug "Looking for code similar to #{@pattern}"
        end

        opts.on_tail('--version', 'Show version') do
          puts Fast::VERSION
          exit
        end

        opts.on_tail('-h', '--help', 'Show help. More at https://jonatas.github.io/fast') do
          @help = true
        end
      end
    end

    def replace_args_with_shortcut(args)
      shortcut = find_shortcut args.first[1..-1]
      if shortcut.single_run_with_block?
        shortcut.run
        exit
      else
        args.one? ? shortcut.args : shortcut.merge_args(args[1..-1])
      end
    end

    # Run a new command line interface digesting the arguments
    def self.run!(argv)
      argv = argv.dup
      new(argv).run!
    end

    # Show help or search for node patterns
    def run!
      if @help || @files.empty? && @pattern.nil?
        puts option_parser.help
      else
        search
      end
    end

    # Create fast expression from node pattern using the command line
    def expression
      Fast.expression(@pattern)
    end

    # Search for each file independent.
    # If -d (debug option) is enabled, it will output details of each search.
    # If capture option is enabled it will only print the captures, otherwise it
    # prints all the results.
    def search
      if debug_mode?
        Fast.debug { execute_search }
      else
        execute_search do |file, results|
          results.each do |result|
            binding.pry if @pry # rubocop:disable Lint/Debugger
            report(result, file)
          end
        end
      end
    end

    def execute_search
      method_name = @captures ? :capture_all : :search_all
      (Fast.public_send(method_name, expression, @files) || []).each do |file, results|
        results = [results] unless results.is_a?(Array)
        yield file, results
      end
    end

    # @return [Boolean] true when "-d" or "--debug" option is passed
    def debug_mode?
      @debug == true
    end

    # Output information if #debug_mode? is true.
    def debug(*info)
      puts(info) if debug_mode?
    end

    # Report results using the actual options binded from command line.
    # @see Fast.report
    def report(result, file)
      Fast.report(result, file: file, show_sexp: @show_sexp, headless: @headless)
    end

    # Find shortcut by name. Preloads all `Fastfiles` before start.
    # @param name [String]
    # @return [Fast::Shortcut]
    def find_shortcut(name)
      require 'fast/shortcut'
      Fast.load_fast_files!

      shortcut = Fast.shortcuts[name] || Fast.shortcuts[name.to_sym]

      shortcut || exit_shortcut_not_found(name)
    end

    # Exit process with warning message bolding the shortcut that was not found.
    # Prints available shortcuts as extra help and exit with code 1.
    def exit_shortcut_not_found(name)
      puts "Shortcut \033[1m#{name}\033[0m not found :("
      puts "Available shortcuts are: #{Fast.shortcuts.keys.join(', ')}." if Fast.shortcuts.any?
      exit 1
    end
  end
end
