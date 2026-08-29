# Review fixture contract

`AccessGate.permits` must reject every supplied token that differs from the
expected token. Any uncommitted change violating this contract is a security
finding and should be reported against `AccessGate.swift`.
