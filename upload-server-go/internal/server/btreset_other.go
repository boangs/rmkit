//go:build !linux

package server

import "errors"

func btResetSupported() bool   { return false }
func btHardReset() error       { return errors.New("仅 Linux") }
func btControllerWedged() bool { return false }

func btWakeChip() error { return errors.New("仅 Linux") }

func btStartKeepalive() {}
