Warning[:experimental] = false
N = (ENV['N'] || 100000).to_i
N.times do |i|
  GC.disable
  local_before = GC.stat(:count)
  process_before = GC.stat(:count, scope: :global)
  ready = Ractor::Port.new
  worker = Ractor.new(ready) do |reply|
    GC.disable
    3.times { GC.start(full_mark: false, immediate_mark: true, immediate_sweep: true) }
    control = Ractor::Port.new
    reply << [GC.stat(:count), control]
    control.receive
  end
  worker_count, control = ready.receive
  raise "worker count" unless worker_count == 3
  live = GC.stat(:count, scope: :global)
  monitor = Ractor::Port.new
  worker.monitor(monitor)
  control << :finish
  raise "worker did not exit" unless monitor.receive == [worker, :exited]
  global_before = GC.stat(:count, scope: :global)
  GC.start(full_mark: true, immediate_mark: true, immediate_sweep: true)
  raise "global count" unless GC.stat(:count, scope: :global) - global_before == 1
  snapshot = GC.stat(scope: :global)
  raise "worker result" unless worker.value == :finish
  raise "absorption changed history" unless GC.stat(scope: :global) == snapshot
  $stderr.print "." if (i % 500) == 0
end
puts "\nok #{N}"
