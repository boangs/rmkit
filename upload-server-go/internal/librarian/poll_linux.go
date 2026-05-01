//go:build linux

package librarian

import "golang.org/x/sys/unix"

type pollFd = unix.PollFd

const pollIn = unix.POLLIN

func poll(fds []pollFd, timeoutMs int) (int, error) {
	return unix.Poll(fds, timeoutMs)
}
