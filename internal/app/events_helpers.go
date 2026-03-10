package app

import (
	ui "github.com/metaspartan/gotui/v5"
)

func toggleInfoLayout() {
	renderMutex.Lock()
	if currentConfig.DefaultLayout == LayoutInfo {
		if lastActiveLayout != "" {
			currentConfig.DefaultLayout = lastActiveLayout
		} else {
			currentConfig.DefaultLayout = LayoutDefault
		}
		for i, layout := range layoutOrder {
			if layout == currentConfig.DefaultLayout {
				currentLayoutNum = i
				break
			}
		}
	} else {
		lastActiveLayout = currentConfig.DefaultLayout
		currentConfig.DefaultLayout = LayoutInfo
		for i, layout := range layoutOrder {
			if layout == LayoutInfo {
				currentLayoutNum = i
				break
			}
		}
	}
	applyLayout(currentConfig.DefaultLayout)
	w, h := ui.TerminalDimensions()
	drawScreen(w, h)
	renderMutex.Unlock()
}

func toggleFanLayout() {
	renderMutex.Lock()
	if currentConfig.DefaultLayout == LayoutFan {
		if lastActiveLayout != "" {
			currentConfig.DefaultLayout = lastActiveLayout
		} else {
			currentConfig.DefaultLayout = LayoutDefault
		}
		for i, layout := range layoutOrder {
			if layout == currentConfig.DefaultLayout {
				currentLayoutNum = i
				break
			}
		}
	} else {
		lastActiveLayout = currentConfig.DefaultLayout
		currentConfig.DefaultLayout = LayoutFan
		infoScrollOffset = 0
		for i, layout := range layoutOrder {
			if layout == LayoutFan {
				currentLayoutNum = i
				break
			}
		}
	}
	applyLayout(currentConfig.DefaultLayout)
	updateInfoUI()
	w, h := ui.TerminalDimensions()
	drawScreen(w, h)
	renderMutex.Unlock()
}

const fanRPMStep = 100

func handleFanSpeedAdjust(key string) {
	renderMutex.Lock()
	defer renderMutex.Unlock()

	if len(lastCPUMetrics.Fans) == 0 {
		return
	}

	for _, fan := range lastCPUMetrics.Fans {
		_ = SetFanForceTest(true)
		_ = SetFanMode(fan.ID, 1) // forced mode

		newRPM := fan.TargetRPM
		if key == "+" || key == "=" {
			newRPM += fanRPMStep
		} else {
			newRPM -= fanRPMStep
		}
		_ = SetFanTarget(fan.ID, newRPM)
	}
	updateInfoUI()
	w, h := ui.TerminalDimensions()
	drawScreen(w, h)
}

func handleFanAutoToggle() {
	renderMutex.Lock()
	defer renderMutex.Unlock()

	if len(lastCPUMetrics.Fans) == 0 {
		return
	}

	anyManual := false
	for _, fan := range lastCPUMetrics.Fans {
		if fan.Mode == 0 {
			// Switching to manual — enable force test first
			_ = SetFanForceTest(true)
			_ = SetFanMode(fan.ID, 1)
			anyManual = true
		} else {
			_ = SetFanMode(fan.ID, 0)
		}
	}
	// Only disable force test if no fans remain in manual mode
	if !anyManual {
		_ = SetFanForceTest(false)
	}
	updateInfoUI()
	w, h := ui.TerminalDimensions()
	drawScreen(w, h)
}

func handleFanSetMin() {
	renderMutex.Lock()
	defer renderMutex.Unlock()

	for _, fan := range lastCPUMetrics.Fans {
		_ = SetFanForceTest(true)
		_ = SetFanMode(fan.ID, 1)
		_ = SetFanTarget(fan.ID, fan.MinRPM)
	}
	updateInfoUI()
	w, h := ui.TerminalDimensions()
	drawScreen(w, h)
}

func handleFanSetMax() {
	renderMutex.Lock()
	defer renderMutex.Unlock()

	for _, fan := range lastCPUMetrics.Fans {
		_ = SetFanForceTest(true)
		_ = SetFanMode(fan.ID, 1)
		_ = SetFanTarget(fan.ID, fan.MaxRPM)
	}
	updateInfoUI()
	w, h := ui.TerminalDimensions()
	drawScreen(w, h)
}

func handleFanResetAuto() {
	renderMutex.Lock()
	defer renderMutex.Unlock()

	_ = ResetFansToAuto()
	updateInfoUI()
	w, h := ui.TerminalDimensions()
	drawScreen(w, h)
}

func handleThemeCycle() {
	renderMutex.Lock()
	w, h := ui.TerminalDimensions()
	updateLayout(w, h)
	cycleTheme()
	renderMutex.Unlock()
	renderMutex.Lock()
	updateProcessList()
	w, h = ui.TerminalDimensions()
	drawScreen(w, h)
	renderMutex.Unlock()
}

func handleLayoutCycle() {
	renderMutex.Lock()
	cycleLayout()
	renderMutex.Unlock()
	saveConfig()
	renderMutex.Lock()
	w, h := ui.TerminalDimensions()
	drawScreen(w, h)
	renderMutex.Unlock()
}

func handleBackgroundCycle() {
	renderMutex.Lock()
	cycleBackground()
	w, h := ui.TerminalDimensions()
	drawScreen(w, h)
	renderMutex.Unlock()
}

func toggleFreeze() {
	renderMutex.Lock()
	isFrozen = !isFrozen
	updateProcessList() // To redraw title with [FROZEN]
	w, h := ui.TerminalDimensions()
	drawScreen(w, h)
	renderMutex.Unlock()
}
