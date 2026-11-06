package android.os;

// roam-helpers fake: a "binder" that carries the in-process implementation Stub.asInterface returns.
public final class FakeBinder implements IBinder {
    public final Object impl;

    public FakeBinder(Object impl) {
        this.impl = impl;
    }
}
