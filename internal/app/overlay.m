// Copyright (c) 2024-2026 Carsen Klock under MIT License
// overlay.m - Native macOS floating overlay HUD window

#import <Cocoa/Cocoa.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define OVERLAY_SPARKLINE_HISTORY 60

// ---------- Metrics struct (passed from Go) ----------

typedef struct {
  double cpu_percent;
  double gpu_percent;
  double ane_percent;
  int gpu_freq_mhz;
  uint64_t mem_used_bytes;
  uint64_t mem_total_bytes;
  uint64_t swap_used_bytes;
  uint64_t swap_total_bytes;
  double total_watts;
  double package_watts;
  double cpu_watts;
  double gpu_watts;
  double ane_watts;
  double dram_watts;
  double soc_temp;
  double cpu_temp;
  double gpu_temp;
  char thermal_state[32];
  char model_name[128];
  int gpu_core_count;
  int e_core_count;
  int p_core_count;
  int s_core_count;
  int ecluster_freq_mhz;
  double ecluster_active;
  int pcluster_freq_mhz;
  double pcluster_active;
  int scluster_freq_mhz;
  double scluster_active;
  double net_in_bytes_per_sec;
  double net_out_bytes_per_sec;
  double disk_read_kb_per_sec;
  double disk_write_kb_per_sec;
  double tflops_fp32;
  char rdma_status[64];
  double dram_bw_combined_gbs;
  int fan_count;
  int fan_rpm[4];
  char fan_name[4][32];
} overlay_metrics_t;

// ---------- Config struct ----------

typedef struct {
  int show_cpu;
  int show_gpu;
  int show_ane;
  int show_memory;
  int show_power;
  int show_temps;
  int show_thermals;
  int show_fans;
  int show_bandwidth;
  int show_network;
  int show_gpu_freq;
  double opacity;
} overlay_config_t;

// ---------- Global state ----------

static overlay_config_t g_overlay_config = {
    .show_cpu = 1,
    .show_gpu = 1,
    .show_ane = 1,
    .show_memory = 1,
    .show_power = 1,
    .show_temps = 1,
    .show_thermals = 1,
    .show_fans = 1,
    .show_bandwidth = 1,
    .show_network = 1,
    .show_gpu_freq = 1,
    .opacity = 0.88,
};

static overlay_metrics_t g_overlay_metrics;
static double cpuSparkHistory[OVERLAY_SPARKLINE_HISTORY] = {0};
static double gpuSparkHistory[OVERLAY_SPARKLINE_HISTORY] = {0};

static void pushSparkHistory(double *buf, double val) {
  memmove(buf, buf + 1, (OVERLAY_SPARKLINE_HISTORY - 1) * sizeof(double));
  buf[OVERLAY_SPARKLINE_HISTORY - 1] = val;
}

// ---------- Forward declarations ----------

@class OverlayContentView;
@class OverlayWindow;

static OverlayWindow *g_overlayWindow = nil;
static OverlayContentView *g_contentView = nil;

// ---------- Color helpers ----------

// Neon green terminal aesthetic
static NSColor *overlayNeonGreen(void) {
  return [NSColor colorWithRed:0.15 green:1.0 blue:0.30 alpha:1.0];
}
static NSColor *overlayAccentGreen(void) {
  return [NSColor colorWithRed:0.15 green:1.0 blue:0.30 alpha:1.0];
}
static NSColor *overlayAccentOrange(void) {
  return [NSColor colorWithRed:1.0 green:0.65 blue:0.10 alpha:1.0];
}
static NSColor *overlayAccentCyan(void) {
  return [NSColor colorWithRed:0.20 green:0.95 blue:0.95 alpha:1.0];
}
static NSColor *overlayAccentPurple(void) {
  return [NSColor colorWithRed:0.75 green:0.45 blue:1.0 alpha:1.0];
}
static NSColor *overlayAccentRed(void) {
  return [NSColor colorWithRed:1.0 green:0.25 blue:0.20 alpha:1.0];
}
static NSColor *overlayAccentYellow(void) {
  return [NSColor colorWithRed:1.0 green:0.92 blue:0.20 alpha:1.0];
}
static NSColor *overlayAccentBlue(void) {
  return [NSColor colorWithRed:0.30 green:0.60 blue:1.0 alpha:1.0];
}
static NSColor *overlayDimText(void) {
  return [NSColor colorWithRed:0.10 green:0.75 blue:0.22 alpha:1.0];
}
static NSColor *overlayBrightText(void) {
  return [NSColor colorWithRed:0.15 green:1.0 blue:0.30 alpha:1.0];
}

// ---------- Throughput formatter ----------

static NSString *formatOverlayThroughput(double bps) {
  if (bps < 1024.0)
    return [NSString stringWithFormat:@"%.0fB/s", bps];
  if (bps < 1024.0 * 1024.0)
    return [NSString stringWithFormat:@"%.1fKB/s", bps / 1024.0];
  if (bps < 1024.0 * 1024.0 * 1024.0)
    return [NSString stringWithFormat:@"%.1fMB/s", bps / (1024.0 * 1024.0)];
  return [NSString
      stringWithFormat:@"%.2fGB/s", bps / (1024.0 * 1024.0 * 1024.0)];
}

// ---------- Color for percentage ----------

static NSColor *colorForPercent(double pct) {
  if (pct >= 80.0)
    return overlayAccentRed();
  if (pct >= 50.0)
    return overlayAccentYellow();
  return overlayAccentGreen();
}

// ---------- Custom NSWindow subclass ----------

@interface OverlayWindow : NSWindow
@end

@implementation OverlayWindow

- (BOOL)canBecomeKeyWindow {
  return NO;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  return NSDragOperationNone;
}

@end

// ---------- Content view ----------

@interface OverlayContentView : NSView {
  NSPoint _dragStart;
  NSPoint _windowStart;
  BOOL _dragging;
}
@end

@implementation OverlayContentView

- (BOOL)isFlipped {
  return YES;
}

// Allow dragging the window by dragging anywhere on the overlay
- (void)mouseDown:(NSEvent *)event {
  _dragStart = [NSEvent mouseLocation];
  _windowStart = self.window.frame.origin;
  _dragging = YES;
}

- (void)mouseDragged:(NSEvent *)event {
  if (!_dragging)
    return;
  NSPoint current = [NSEvent mouseLocation];
  CGFloat dx = current.x - _dragStart.x;
  CGFloat dy = current.y - _dragStart.y;
  NSPoint newOrigin =
      NSMakePoint(_windowStart.x + dx, _windowStart.y + dy);
  [self.window setFrameOrigin:newOrigin];
}

- (void)mouseUp:(NSEvent *)event {
  _dragging = NO;
}

// ---------- Drawing ----------

static void drawMiniSparkline(double *data, int count, CGFloat x, CGFloat y,
                              CGFloat w, CGFloat h, NSColor *color) {
  if (count < 2)
    return;

  double maxVal = 100.0;
  NSBezierPath *fill = [NSBezierPath bezierPath];
  [fill moveToPoint:NSMakePoint(x, y + h)];

  for (int i = 0; i < count; i++) {
    CGFloat px = x + ((CGFloat)i / (CGFloat)(count - 1)) * w;
    CGFloat val = data[i];
    if (val < 0) val = 0;
    if (val > maxVal) val = maxVal;
    CGFloat py = y + h - (val / maxVal) * h;
    [fill lineToPoint:NSMakePoint(px, py)];
  }

  [fill lineToPoint:NSMakePoint(x + w, y + h)];
  [fill closePath];

  [[color colorWithAlphaComponent:0.25] set];
  [fill fill];

  // Draw line on top
  NSBezierPath *line = [NSBezierPath bezierPath];
  for (int i = 0; i < count; i++) {
    CGFloat px = x + ((CGFloat)i / (CGFloat)(count - 1)) * w;
    CGFloat val = data[i];
    if (val < 0) val = 0;
    if (val > maxVal) val = maxVal;
    CGFloat py = y + h - (val / maxVal) * h;
    if (i == 0)
      [line moveToPoint:NSMakePoint(px, py)];
    else
      [line lineToPoint:NSMakePoint(px, py)];
  }
  [line setLineWidth:1.5];
  [[color colorWithAlphaComponent:0.9] set];
  [line stroke];
}

static void drawMiniBar(CGFloat x, CGFloat y, CGFloat w, CGFloat h,
                        double pct, NSColor *color) {
  CGFloat radius = h / 2.0;

  // Track
  [[NSColor colorWithWhite:1.0 alpha:0.08] set];
  NSBezierPath *track =
      [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, w, h)
                                      xRadius:radius
                                      yRadius:radius];
  [track fill];

  // Fill
  CGFloat fillW = (pct / 100.0) * w;
  if (fillW < 1.0 && pct > 0)
    fillW = 1.0;
  if (fillW > 0) {
    [color set];
    NSBezierPath *bar = [NSBezierPath
        bezierPathWithRoundedRect:NSMakeRect(x, y, fillW, h)
                          xRadius:radius
                          yRadius:radius];
    [bar fill];
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];

  overlay_metrics_t m = g_overlay_metrics;
  overlay_config_t cfg = g_overlay_config;

  CGFloat W = self.bounds.size.width;
  CGFloat padX = 12;
  CGFloat contentW = W - padX * 2;
  __block CGFloat y = 14;

  NSFont *headerFont =
      [NSFont systemFontOfSize:16 weight:NSFontWeightBold];
  NSFont *subHeaderFont =
      [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
  NSFont *labelFont = [NSFont monospacedDigitSystemFontOfSize:14
                                                        weight:NSFontWeightMedium];
  NSFont *valueFont = [NSFont monospacedDigitSystemFontOfSize:14
                                                        weight:NSFontWeightBold];
  NSFont *smallFont = [NSFont monospacedDigitSystemFontOfSize:11
                                                        weight:NSFontWeightRegular];

  NSDictionary *headerAttrs = @{
    NSFontAttributeName : headerFont,
    NSForegroundColorAttributeName : overlayBrightText()
  };
  NSDictionary *subHeaderAttrs = @{
    NSFontAttributeName : subHeaderFont,
    NSForegroundColorAttributeName : overlayDimText()
  };
  NSDictionary *labelAttrs = @{
    NSFontAttributeName : labelFont,
    NSForegroundColorAttributeName : overlayNeonGreen()
  };
  NSDictionary *smallAttrs = @{
    NSFontAttributeName : smallFont,
    NSForegroundColorAttributeName : overlayDimText()
  };

  // ---- mactop header ----
  NSString *title = @"mactop";
  NSDictionary *titleAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:15 weight:NSFontWeightHeavy],
    NSForegroundColorAttributeName : overlayNeonGreen()
  };
  NSSize titleSize = [title sizeWithAttributes:titleAttrs];
  [title drawAtPoint:NSMakePoint(padX, y) withAttributes:titleAttrs];

  // Dot separator
  NSString *dot = @"•";
  NSDictionary *dotAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
    NSForegroundColorAttributeName :
        [NSColor colorWithWhite:0.5 alpha:1.0]
  };
  [dot drawAtPoint:NSMakePoint(padX + titleSize.width + 5, y + 1.5)
      withAttributes:dotAttrs];

  // Model name
  NSString *modelName =
      [NSString stringWithUTF8String:m.model_name];
  if (modelName.length == 0)
    modelName = @"Apple Silicon";
  NSSize dotSize = [dot sizeWithAttributes:dotAttrs];
  [modelName
      drawAtPoint:NSMakePoint(padX + titleSize.width + 5 + dotSize.width + 5,
                               y + 0.5)
      withAttributes:subHeaderAttrs];
  y += 22;

  // Core summary line
  NSMutableString *coreSummary = [NSMutableString string];
  if (m.e_core_count > 0)
    [coreSummary appendFormat:@"%dE", m.e_core_count];
  if (m.p_core_count > 0) {
    if (coreSummary.length > 0)
      [coreSummary appendString:@"/"];
    [coreSummary appendFormat:@"%dP", m.p_core_count];
  }
  if (m.s_core_count > 0) {
    if (coreSummary.length > 0)
      [coreSummary appendString:@"/"];
    [coreSummary appendFormat:@"%dS", m.s_core_count];
  }
  if (m.gpu_core_count > 0) {
    [coreSummary appendFormat:@" • %d GPU Cores", m.gpu_core_count];
  }
  [coreSummary drawAtPoint:NSMakePoint(padX, y)
               withAttributes:smallAttrs];
  y += 18;

  // Separator
  [[NSColor colorWithWhite:1.0 alpha:0.08] set];
  [NSBezierPath fillRect:NSMakeRect(padX, y, contentW, 1)];
  y += 6;

  // ---- Metric rows ----
  CGFloat rowH = 24;
  CGFloat barX = padX + 80;
  CGFloat barW = contentW - 80 - 60; // Leave room for % text
  CGFloat barH = 6;
  CGFloat sparkW = 56;
  CGFloat sparkH = 18;

  // Helper block for labeled metric row with bar
  void (^drawMetricBar)(NSString *, double, NSColor *, double *, BOOL) =
      ^(NSString *label, double pct, NSColor *color, double *sparkData,
        BOOL showSpark) {
        // Label
        [label drawAtPoint:NSMakePoint(padX, y + 2) withAttributes:labelAttrs];

        // Bar
        drawMiniBar(barX, y + 7, barW - (showSpark ? sparkW + 6 : 0), barH,
                    pct, color);

        // Sparkline
        if (showSpark && sparkData) {
          drawMiniSparkline(sparkData, OVERLAY_SPARKLINE_HISTORY,
                            padX + contentW - sparkW - 38, y + 1, sparkW,
                            sparkH, color);
        }

        // Value
        NSString *val = [NSString stringWithFormat:@"%.0f%%", pct];
        NSDictionary *valAttrs = @{
          NSFontAttributeName : valueFont,
          NSForegroundColorAttributeName : colorForPercent(pct)
        };
        NSSize valSize = [val sizeWithAttributes:valAttrs];
        [val drawAtPoint:NSMakePoint(padX + contentW - valSize.width, y + 1)
            withAttributes:valAttrs];

        y += rowH;
      };

  // Helper block for labeled key-value row
  void (^drawMetricKV)(NSString *, NSString *, NSColor *) =
      ^(NSString *label, NSString *value, NSColor *color) {
        [label drawAtPoint:NSMakePoint(padX, y + 2)
            withAttributes:labelAttrs];
        NSDictionary *valAttrs = @{
          NSFontAttributeName : valueFont,
          NSForegroundColorAttributeName : color
        };
        NSSize valSize = [value sizeWithAttributes:valAttrs];
        [value drawAtPoint:NSMakePoint(padX + contentW - valSize.width, y + 1)
            withAttributes:valAttrs];
        y += rowH;
      };

  // CPU
  if (cfg.show_cpu) {
    drawMetricBar(@"CPU", m.cpu_percent, overlayAccentGreen(), cpuSparkHistory,
                  YES);
  }

  // GPU
  if (cfg.show_gpu) {
    drawMetricBar(@"GPU", m.gpu_percent, overlayAccentOrange(), gpuSparkHistory,
                  YES);
  }

  // ANE
  if (cfg.show_ane) {
    drawMetricBar(@"ANE", m.ane_percent, overlayAccentCyan(), NULL, NO);
  }

  // Memory
  if (cfg.show_memory) {
    double memGB = (double)m.mem_used_bytes / (1024.0 * 1024.0 * 1024.0);
    double totalGB = (double)m.mem_total_bytes / (1024.0 * 1024.0 * 1024.0);
    double memPct = totalGB > 0 ? (memGB / totalGB) * 100.0 : 0;
    NSString *memStr =
        [NSString stringWithFormat:@"%.1f/%.0fGB", memGB, totalGB];
    [(@"Memory") drawAtPoint:NSMakePoint(padX, y + 3)
                 withAttributes:labelAttrs];
    drawMiniBar(barX, y + 9, barW - sparkW - 6, barH, memPct,
                overlayAccentPurple());
    NSDictionary *valAttrs = @{
      NSFontAttributeName : valueFont,
      NSForegroundColorAttributeName : colorForPercent(memPct)
    };
    NSSize valSize = [memStr sizeWithAttributes:valAttrs];
    [memStr drawAtPoint:NSMakePoint(padX + contentW - valSize.width, y + 2)
        withAttributes:valAttrs];
    y += rowH;

    // Swap — full bar like memory
    if (m.swap_total_bytes > 0) {
      double swapGB =
          (double)m.swap_used_bytes / (1024.0 * 1024.0 * 1024.0);
      double swapTotalGB =
          (double)m.swap_total_bytes / (1024.0 * 1024.0 * 1024.0);
      double swapPct = swapTotalGB > 0 ? (swapGB / swapTotalGB) * 100.0 : 0;
      NSString *swapStr =
          [NSString stringWithFormat:@"%.1f/%.0fGB", swapGB, swapTotalGB];
      [(@"Swap") drawAtPoint:NSMakePoint(padX, y + 3)
                 withAttributes:labelAttrs];
      drawMiniBar(barX, y + 9, barW - sparkW - 6, barH, swapPct,
                  overlayAccentOrange());
      NSDictionary *swapValAttrs = @{
        NSFontAttributeName : valueFont,
        NSForegroundColorAttributeName : colorForPercent(swapPct)
      };
      NSSize swapValSize = [swapStr sizeWithAttributes:swapValAttrs];
      [swapStr drawAtPoint:NSMakePoint(padX + contentW - swapValSize.width, y + 2)
          withAttributes:swapValAttrs];
      y += rowH;
    }
  }

  // Separator
  [[NSColor colorWithWhite:1.0 alpha:0.06] set];
  [NSBezierPath fillRect:NSMakeRect(padX, y, contentW, 1)];
  y += 5;

  // Power
  if (cfg.show_power) {
    NSString *powerStr =
        [NSString stringWithFormat:@"%.1fW", m.package_watts];
    drawMetricKV(@"Power", powerStr, overlayAccentYellow());

    // Breakdown (compact)
    NSString *breakdownStr = [NSString
        stringWithFormat:@"CPU %.1fW  GPU %.1fW  ANE %.1fW", m.cpu_watts,
                         m.gpu_watts, m.ane_watts];
    [breakdownStr drawAtPoint:NSMakePoint(padX + 10, y + 1)
                  withAttributes:smallAttrs];
    y += 14;
  }

  // DRAM Bandwidth
  if (cfg.show_bandwidth) {
    NSString *bwStr =
        [NSString stringWithFormat:@"%.1f GB/s", m.dram_bw_combined_gbs];
    drawMetricKV(@"DRAM BW", bwStr, overlayAccentBlue());
  }

  // GPU Freq + TFLOPs
  if (cfg.show_gpu_freq) {
    NSString *freqStr;
    if (m.tflops_fp32 > 0) {
      freqStr = [NSString
          stringWithFormat:@"%d MHz  %.1f TF", m.gpu_freq_mhz,
                           m.tflops_fp32];
    } else {
      freqStr = [NSString stringWithFormat:@"%d MHz", m.gpu_freq_mhz];
    }
    drawMetricKV(@"GPU Freq", freqStr, overlayAccentOrange());
  }

  // Separator
  [[NSColor colorWithWhite:1.0 alpha:0.06] set];
  [NSBezierPath fillRect:NSMakeRect(padX, y, contentW, 1)];
  y += 5;

  // Temps
  if (cfg.show_temps) {
    NSString *tempStr;
    if (m.gpu_temp > 0) {
      tempStr = [NSString
          stringWithFormat:@"CPU %.0f°C  GPU %.0f°C", m.cpu_temp, m.gpu_temp];
    } else {
      tempStr = [NSString stringWithFormat:@"%.0f°C", m.cpu_temp];
    }
    NSColor *tempColor = overlayBrightText();
    if (m.cpu_temp >= 90 || m.gpu_temp >= 90)
      tempColor = overlayAccentRed();
    else if (m.cpu_temp >= 70 || m.gpu_temp >= 70)
      tempColor = overlayAccentYellow();
    drawMetricKV(@"Temps", tempStr, tempColor);
  }

  // Thermal state
  if (cfg.show_thermals) {
    NSString *thermalStr =
        [NSString stringWithUTF8String:m.thermal_state];
    if (thermalStr.length == 0)
      thermalStr = @"Unknown";
    NSColor *thermalColor = overlayAccentGreen();
    if ([thermalStr containsString:@"Critical"])
      thermalColor = overlayAccentRed();
    else if ([thermalStr containsString:@"Serious"])
      thermalColor = overlayAccentRed();
    else if ([thermalStr containsString:@"Fair"])
      thermalColor = overlayAccentYellow();
    drawMetricKV(@"Thermal", thermalStr, thermalColor);
  }

  // Fans
  if (cfg.show_fans && m.fan_count > 0) {
    NSMutableString *fanStr = [NSMutableString string];
    for (int i = 0; i < m.fan_count && i < 4; i++) {
      if (i > 0)
        [fanStr appendString:@"  "];
      [fanStr appendFormat:@"%dRPM", m.fan_rpm[i]];
    }
    drawMetricKV(@"Fans", fanStr, overlayDimText());
  }

  // Network
  if (cfg.show_network) {
    NSString *netStr = [NSString
        stringWithFormat:@"↓%@ ↑%@",
                         formatOverlayThroughput(m.net_in_bytes_per_sec),
                         formatOverlayThroughput(m.net_out_bytes_per_sec)];
    drawMetricKV(@"Network", netStr, overlayDimText());
  }
}

@end

// ---------- C API ----------

int initOverlay(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    // Calculate initial height based on enabled sections
    CGFloat estimatedHeight = 380; // Base height for header + always-on sections
    // Each section adds roughly 24px with larger text
    if (g_overlay_config.show_fans)
      estimatedHeight += 24;
    if (g_overlay_config.show_network)
      estimatedHeight += 24;
    if (g_overlay_config.show_bandwidth)
      estimatedHeight += 24;
    if (g_overlay_config.show_gpu_freq)
      estimatedHeight += 24;

    CGFloat overlayW = 340;
    CGFloat overlayH = estimatedHeight;

    // Position in top-left with padding
    NSScreen *screen = [NSScreen mainScreen];
    NSRect screenFrame = screen.visibleFrame;
    CGFloat posX = screenFrame.origin.x + 16;
    CGFloat posY = screenFrame.origin.y + screenFrame.size.height - overlayH - 16;

    NSRect frame = NSMakeRect(posX, posY, overlayW, overlayH);

    g_overlayWindow = [[OverlayWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];

    g_overlayWindow.level = NSStatusWindowLevel + 1;
    g_overlayWindow.opaque = NO;
    g_overlayWindow.hasShadow = YES;
    g_overlayWindow.ignoresMouseEvents = NO;
    g_overlayWindow.backgroundColor = [NSColor clearColor];
    g_overlayWindow.alphaValue = g_overlay_config.opacity;

    // Appear on all Spaces, including fullscreen
    g_overlayWindow.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorStationary |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorIgnoresCycle;

    // Solid black background with rounded corners
    NSView *bgView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, overlayW, overlayH)];
    bgView.wantsLayer = YES;
    bgView.layer.backgroundColor = [[NSColor colorWithRed:0.05 green:0.05 blue:0.05 alpha:0.92] CGColor];
    bgView.layer.cornerRadius = 14.0;
    bgView.layer.masksToBounds = YES;
    bgView.layer.borderWidth = 1.0;
    bgView.layer.borderColor = [[NSColor colorWithRed:0.15 green:1.0 blue:0.30 alpha:0.3] CGColor];
    bgView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    g_overlayWindow.contentView = bgView;

    // Content view for drawing metrics
    g_contentView = [[OverlayContentView alloc]
        initWithFrame:NSMakeRect(0, 0, overlayW, overlayH)];
    g_contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [bgView addSubview:g_contentView];

    [g_overlayWindow orderFrontRegardless];

    return 0;
  }
}

void setOverlayConfig(overlay_config_t *cfg) {
  if (cfg) {
    g_overlay_config = *cfg;
  }
}

void updateOverlayMetrics(overlay_metrics_t *m) {
  if (!m)
    return;
  dispatch_async(dispatch_get_main_queue(), ^{
    g_overlay_metrics = *m;
    pushSparkHistory(cpuSparkHistory, m->cpu_percent);
    pushSparkHistory(gpuSparkHistory, m->gpu_percent);

    // Dynamically resize window based on content
    CGFloat rowH = 24;
    CGFloat baseH = 105; // Header + core line + first separator (larger)
    int rows = 0;

    if (g_overlay_config.show_cpu) rows++;
    if (g_overlay_config.show_gpu) rows++;
    if (g_overlay_config.show_ane) rows++;
    if (g_overlay_config.show_memory) {
      rows++;
      if (m->swap_total_bytes > 0)
        rows++; // Swap bar row
    }
    baseH += 8; // separator

    if (g_overlay_config.show_power) {
      rows++;
      baseH += 16; // breakdown sub-row
    }
    if (g_overlay_config.show_bandwidth) rows++;
    if (g_overlay_config.show_gpu_freq) rows++;
    baseH += 8; // separator

    if (g_overlay_config.show_temps) rows++;
    if (g_overlay_config.show_thermals) rows++;
    if (g_overlay_config.show_fans && m->fan_count > 0) rows++;
    if (g_overlay_config.show_network) rows++;

    CGFloat newH = baseH + rows * rowH + 14; // 14px bottom padding

    NSRect frame = g_overlayWindow.frame;
    if ((int)frame.size.height != (int)newH) {
      // Keep top-left pinned
      CGFloat dy = newH - frame.size.height;
      frame.origin.y -= dy;
      frame.size.height = newH;
      [g_overlayWindow setFrame:frame display:NO];

      // Resize subviews
      NSView *bgView = g_overlayWindow.contentView;
      bgView.frame = NSMakeRect(0, 0, frame.size.width, newH);
      g_contentView.frame = NSMakeRect(0, 0, frame.size.width, newH);
    }

    [g_contentView setNeedsDisplay:YES];
  });
}

void runOverlayLoop(void) { [NSApp run]; }

void cleanupOverlay(void) {
  if (g_overlayWindow) {
    [g_overlayWindow close];
    g_overlayWindow = nil;
  }
  g_contentView = nil;
}
