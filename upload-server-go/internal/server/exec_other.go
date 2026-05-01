//go:build !linux

package server

import "syscall"

func newSessionLeader() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{}
}
