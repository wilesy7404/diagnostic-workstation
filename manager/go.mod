module diagnosticworkstation/manager

go 1.23.2

// Go 1.20 runtime defaults. The no-module Oct 14 binary also has netedns0=0;
// this line does not emit that setting, because its default changed in Go 1.19.
godebug default=go1.20
