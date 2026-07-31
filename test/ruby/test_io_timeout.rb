# frozen_string_literal: false

require 'io/nonblock'

class TestIOTimeout < Test::Unit::TestCase
  def with_pipe
    begin
      i, o = IO.pipe

      yield i, o
    ensure
      i.close
      o.close
    end
  end

  def test_timeout_attribute
    with_pipe do |i, o|
      assert_nil i.timeout

      i.timeout = 10
      assert_equal 10, i.timeout
      assert_nil o.timeout

      o.timeout = 20
      assert_equal 20, o.timeout
      assert_equal 10, i.timeout
    end
  end

  def test_timeout_read_exception
    with_pipe do |i, o|
      i.timeout = 0.0001

      assert_raise(IO::TimeoutError) {i.read}
    end
  end

  def test_timeout_read_preserves_buffered_data
    with_pipe do |i, o|
      o.write("Hello")
      i.timeout = 0.0001

      assert_raise(IO::TimeoutError) {i.read}
      assert_equal "Hello", i.read_nonblock(5)
    end
  end

  def test_timeout_gets_exception
    with_pipe do |i, o|
      i.timeout = 0.0001

      assert_raise(IO::TimeoutError) {i.gets}
    end
  end

  def test_timeout_puts
    with_pipe do |i, o|
      i.timeout = 0.0001
      o.puts("Hello World")
      o.close

      assert_equal "Hello World", i.gets.chomp
    end
  end
end
