//go:build !linux

package librarian

import "errors"

type pollFd struct {
	Fd      int32
	Events  int16
	Revents int16
}

const pollIn = 0

func poll(fds []pollFd, timeoutMs int) (int, error) {
	return 0, errors.New("librarian: poll not supported on this OS")
}
