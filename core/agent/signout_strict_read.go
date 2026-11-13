package main

import "time"

// endStoredWalletRead: a session end's strict read of the stored wallet before its switch (h60 #16): two tries in
// one bound. Absent or damaged is readable (REPAIR-WALLET); a failed read or the bound passing is not.
var endStoredWalletReadWait = 20 * time.Second

var endStoredWalletReadTry = func(name, pass string, dk []byte) bool {
	_, ok := storedWalletForPublish("s3", name, pass, dk)
	return ok
}

func endStoredWalletRead(name, pass string, key func() []byte) (readable bool) {
	res := make(chan bool, 1)
	goSafe("end-wallet-read", func() {
		for try := 0; try < 2; try++ {
			if endStoredWalletReadTry(name, pass, key()) {
				res <- true
				return
			}
		}
		res <- false
	})
	select {
	case ok := <-res:
		return ok
	case <-time.After(endStoredWalletReadWait):
		return false
	}
}
