require 'erb'
require 'lib/log'
require 'lib/report-generators/report_templates'
require 'lib/report-generators/reports'
require 'pathname'
require 'stringio'
require 'test/unit/ui/testrunnermediator'
require 'test/unit/ui/testrunnerutilities'
require 'test/unit/testsuite'

require 'pp'

# test suites
require 'basic_tests'
require 'pool_resize_tests'
require 'creation_tests'
require 'deletion_tests'
require 'snapshot_tests'

#----------------------------------------------------------------

def mangle(txt)
  txt.gsub(/\s+/, '_').gsub(/[(]/, '_').gsub(/[)]/, '')
end

class TestOutcome
  attr_accessor :name, :failures, :log

  def initialize(n)
    @name = n
    @faults = Array.new
    @log = StringIO.new
  end

  def add_fault(f)
    @faults << f
  end

  def pass?
    @faults.size == 0
  end

  def get_binding
    binding
  end
end

# based on the console test runner
module Test
  module Unit
    module UI
      class ThinTestRunner
        extend Test::Unit::UI::TestRunnerUtilities

        attr_reader :tests

        # Creates a new TestRunner for running the passed
        # suite. If quiet_mode is true, the output while
        # running is limited to progress dots, errors and
        # failures, and the final result. io specifies
        # where runner output should go to; defaults to
        # STDOUT.
        def initialize(suite, output_level=NORMAL, io=STDOUT)
          @suite = suite
          @output_level = output_level
          @io = io
          @already_outputted = false
          @faults = []

          @total_passed = 0
          @total_failed = 0
          @tests = Array.new
        end

        # Begins the test run.
        def start
          setup_mediator
          attach_to_mediator
          start_mediator
        end

        def get_binding
          binding
        end

        private
        def setup_mediator
          @mediator = create_mediator(@suite)
          suite_name = @suite.to_s
          if @suite.kind_of?(Module)
            suite_name = @suite.name
          end
          output("Loaded suite #{suite_name}")
        end

        def create_mediator(suite)
          return TestRunnerMediator.new(suite)
        end

        def attach_to_mediator
          @mediator.add_listener(TestResult::FAULT, &method(:add_fault))
          @mediator.add_listener(TestRunnerMediator::STARTED, &method(:started))
          @mediator.add_listener(TestRunnerMediator::FINISHED, &method(:finished))
          @mediator.add_listener(TestCase::STARTED, &method(:test_started))
          @mediator.add_listener(TestCase::FINISHED, &method(:test_finished))
        end

        def start_mediator
          @mediator.run_suite
        end

        def add_fault(fault)
          error(fault.long_display)
          @tests[-1].add_fault(fault)

          @faults << fault
          output_single(fault.single_character_display, PROGRESS_ONLY)
          @already_outputted = true
        end

        def started(result)
          @result = result
          output("Started")
        end

        def finished(elapsed_time)
          nl
          output("Finished in #{elapsed_time} seconds.")
          @faults.each_with_index do |fault, index|
            nl
            output("%3d) %s" % [index + 1, fault.long_display])
          end
          nl
          output(@result)
        end

        def result_file(name)
          "./reports/#{mangle(name)}.result"
        end

        def log_file(name)
          "./reports/#{mangle(name)}.result"
        end

        def test_started(name)
          to = TestOutcome.new(name)
          set_log(to.log)
          @tests << to
          output_single(name + ": ", VERBOSE)
        end

        def test_finished(name)
          output_single(".", PROGRESS_ONLY) unless @already_outputted
          nl(VERBOSE)
          @already_outputted = false
        end

        def total_passed
          sum = 0
          @tests.each do |t|
            sum = sum + 1 if t.pass?
          end
          sum
        end

        def total_failed
          @tests.size - total_passed
        end

        def nl(level=NORMAL)
          output("", level)
        end

        def output(something, level=NORMAL)
          @io.puts(something) if output?(level)
          @io.flush
        end

        def output_single(something, level=NORMAL)
          @io.write(something) if output?(level)
          @io.flush
        end

        def output?(level)
          level <= @output_level
        end
      end
    end
  end
end

#----------------------------------------------------------------

include ReportTemplates

suite = Test::Unit::TestSuite.new
[BasicTests, CreationTests, DeletionTests, PoolResizeTests, SnapshotTests].each do |tests|
  suite << tests.suite
end

runner = Test::Unit::UI::ThinTestRunner.new(suite, Test::Unit::UI::VERBOSE)
runner.start
runner.tests.each do |t|
  STDERR.puts "generating report for #{t.name}"
  generate_report(:unit_detail, t.get_binding, Pathname.new("reports/#{mangle(t.name)}.html"))
end
generate_report(:unit_test, runner.get_binding)

#----------------------------------------------------------------