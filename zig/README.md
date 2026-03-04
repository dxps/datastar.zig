# Zig Directory - whats this ?

This dir contains patched kqueue.zig images that enable this datastar.zig code to compile 
with the -Denable-kqueue-fibers option.

Im only using the Io.Kqueue code to tap into the fibers portion - its NOT doing evented IO

The advantage of this is that you can experiment with juggling multiple IO runtimes in your
app at once, and experiment with having long lived handlers instantiated in fibers instead
of threads.  This WILL mean slightly lower throughput performance compared to threads, but it WILL
give much better response latency AND allow a huge number of open connections compared to
threads.

This is obviously all very dangerous and experimental, so ... yeah

In this directory, there are subdirectories tagged with the build version of Zig that
it should be applied to.

Copy the xxxx/Kqueue.zig file from here on top of your $ZIG_PATH/lib/std/Io/Kqueue.zig file,
then try building datastar.zig again with -Denable-kqueue-fibers option.

If it works, then you will see debug output from the Kqueue engine showing fibers being
created and context switched in and out.

Note that using the debug allocator in this mode DOES NOT WORK - so make sure you either
build with -Ooptimize=ReleaseFast/Safe ... or deliberately pass `std.heap.smp_allocator`
as the .allocator to the Server init function.

Enjoy !

# 2490

NOTE - the pubsub lib used to do a timedwait on the std.Thread.Mutex to be able to generate timeout 
events to post to the subscriber

With the changes to std.Io.Mutex and std.Io.Condition ... I cant seem to find the equiv functions
for this yet, so this is all released without timedwait - just does a normal uncancellable wait on the mutex.

This means that receiving "timeout" signals on a subscription are borked till I can work it out
