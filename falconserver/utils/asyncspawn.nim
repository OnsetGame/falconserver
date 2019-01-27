when defined(windows):
    import asyncdispatch

    proc asyncSpawn*[T](v: T): Future[T] {.async.} =
        # TODO: ...
        return v
else:
    import asyncdispatch, threadpool, locks, asyncfile
    import posix except spawn

    type AsyncSpawnCtx = ref object {.inheritable.}
        dispatcher: proc(ctx: AsyncSpawnCtx) {.nimcall.}
        fut: pointer

    var gChannel: Channel[AsyncSpawnCtx]
    gChannel.open()

    var pipeLock: Lock
    var pipeFd: cint


    proc runMainThreadSelector(s: AsyncFile) {.async.} =
        var p: pointer
        while true:
            discard await s.readBuffer(addr p, sizeof(p))
            let ctx = gChannel.recv()
            ctx.dispatcher(ctx)
            GC_unref(cast[RootRef](ctx.fut))

    proc setNonBlocking(fd: cint) {.inline.} =
      var x = fcntl(fd, F_GETFL, 0)
      if x != -1:
        var mode = x or O_NONBLOCK
        discard fcntl(fd, F_SETFL, mode)

    proc initDispatch() =
        initLock(pipeLock)
        var pipeFds: array[2, cint]
        discard posix.pipe(pipeFds)
        pipeFd = pipeFds[1]
        setNonBlocking(pipeFds[0])
        let file = newAsyncFile(AsyncFD(pipeFds[0]))
        asyncCheck runMainThreadSelector(file)

    initDispatch()

    type PerformProcWrapper = object
        pr: proc()

    proc performOnBackgroundThread(o: PerformProcWrapper) =
        o.pr()

    template asyncSpawn*(p: typed): auto =
        block:
            # let a = p
            when compiles(p is void):
                # echo "Compiles"
                type RetType = type(p)
            else:
                type RetType = void

            type Ctx = ref object of AsyncSpawnCtx
                when RetType isnot void:
                    res: RetType

            var f = newFuture[RetType]()
            GC_ref(f)

            let pfut = cast[pointer](f)

            proc disp(ctx: AsyncSpawnCtx) {.nimcall.} =
                let ctx = cast[Ctx](ctx)
                let f = cast[Future[RetType]](ctx.fut)
                when RetType is void:
                    f.complete()
                else:
                    f.complete(ctx.res)

            proc b() =
                var ctx: Ctx
                ctx.new()
                ctx.dispatcher = disp
                ctx.fut = pfut

                when RetType is void:
                    p
                else:
                    ctx.res = p

                gChannel.send(ctx)
                pipeLock.acquire()
                var dummy: pointer
                discard posix.write(pipeFd, unsafeAddr dummy, sizeof(dummy))
                pipeLock.release()

            # This dancing with the wrapper is required because of nim bug #7057

            var w: PerformProcWrapper
            w.pr = b

            threadpool.spawn performOnBackgroundThread(w)
            f


when isMainModule:
    import times, strutils

    proc foo(a: int, b: int): int =
        echo "hi", a, b
        a + b

    proc b() =
        let a = 3
        let i = waitFor asyncSpawn foo(a, 2)
        echo "bye: ", i
        # sync()
        echo "done"

    b()
