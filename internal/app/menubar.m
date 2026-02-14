// Copyright (c) 2024-2026 Carsen Klock under MIT License
// menubar.m - Native macOS menu bar status item using AppKit

#import <Cocoa/Cocoa.h>
#include <dispatch/dispatch.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SPARKLINE_HISTORY_SIZE 60

// Metrics structure passed from Go
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
  int ecluster_freq_mhz;
  double ecluster_active;
  int pcluster_freq_mhz;
  double pcluster_active;
  double net_in_bytes_per_sec;
  double net_out_bytes_per_sec;
  double disk_read_kb_per_sec;
  double disk_write_kb_per_sec;
  double tflops_fp32;
  char rdma_status[64];
} menubar_metrics_t;

// Config passed from Go
typedef struct {
  int status_bar_width;
  int sparkline_width;
  int sparkline_height;
  int show_cpu;
  int show_gpu;
  int show_ane;
  int show_memory;
  int show_power;
  int show_percent;
  char cpu_color[8];
  char gpu_color[8];
  char ane_color[8];
  char mem_color[8];
} menubar_config_t;

// Go callback for persisting settings
extern void GoSaveMenuBarConfig(int statusBarWidth, int showCPU, int showGPU,
                                int showANE, int showMem, int showPower,
                                int showPercent, const char *cpuHex,
                                const char *gpuHex, const char *aneHex,
                                const char *memHex);

// Global state
static menubar_config_t g_config = {
    .status_bar_width = 28,
    .sparkline_width = 420,
    .sparkline_height = 60,
    .show_cpu = 1,
    .show_gpu = 1,
    .show_ane = 1,
    .show_memory = 0,
    .show_power = 1,
    .show_percent = 0,
    .cpu_color = "",
    .gpu_color = "",
    .ane_color = "",
    .mem_color = "",
};

// Sparkline history buffers
static double cpuHistory[SPARKLINE_HISTORY_SIZE] = {0};
static double gpuHistory[SPARKLINE_HISTORY_SIZE] = {0};
static double memHistory[SPARKLINE_HISTORY_SIZE] = {0};
static double aneHistory[SPARKLINE_HISTORY_SIZE] = {0};

static void pushHistory(double *buf, double val) {
  memmove(buf, buf + 1, (SPARKLINE_HISTORY_SIZE - 1) * sizeof(double));
  buf[SPARKLINE_HISTORY_SIZE - 1] = val;
}

// Forward declarations
static NSFont *metricFont(void);
static NSFont *headerFont(void);
static NSImage *drawStatusBarImage(double cpu, double gpu, double ane,
                                   double memPct);
static NSImage *drawSparklineChart(double *history, int count, NSColor *color,
                                   NSString *label, double currentVal,
                                   NSString *valOverride);
static NSString *formatThroughput(double bps);
static void buildMenu(void);
static void persistConfig(void);

// ---- Color helpers ----

static NSColor *colorFromHex(const char *hex) {
  if (hex == NULL || hex[0] == '\0')
    return nil;
  NSString *str = [NSString stringWithUTF8String:hex];
  if ([str hasPrefix:@"#"])
    str = [str substringFromIndex:1];
  if (str.length != 6)
    return nil;
  unsigned int rgb = 0;
  [[NSScanner scannerWithString:str] scanHexInt:&rgb];
  return [NSColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                         green:((rgb >> 8) & 0xFF) / 255.0
                          blue:(rgb & 0xFF) / 255.0
                         alpha:1.0];
}

static NSString *hexFromColor(NSColor *color) {
  NSColor *c = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  if (!c)
    return @"";
  int r = (int)(c.redComponent * 255 + 0.5);
  int g = (int)(c.greenComponent * 255 + 0.5);
  int b = (int)(c.blueComponent * 255 + 0.5);
  return [NSString stringWithFormat:@"#%02X%02X%02X", r, g, b];
}

// Returns configured color or system default
static NSColor *cpuColor(void) {
  NSColor *c = colorFromHex(g_config.cpu_color);
  return c ?: [NSColor systemGreenColor];
}
static NSColor *gpuColor(void) {
  NSColor *c = colorFromHex(g_config.gpu_color);
  return c ?: [NSColor systemOrangeColor];
}
static NSColor *aneColor(void) {
  NSColor *c = colorFromHex(g_config.ane_color);
  return c ?: [NSColor systemCyanColor];
}
static NSColor *memColor(void) {
  NSColor *c = colorFromHex(g_config.mem_color);
  return c ?: [NSColor systemPurpleColor];
}

static NSColor *labelDimColor(void) {
  return [NSColor colorWithWhite:0.55 alpha:1.0];
}
static NSColor *valueColor(void) { return [NSColor whiteColor]; }
static NSColor *headerColor(void) { return [NSColor whiteColor]; }

// ---- Custom NSView-based menu items ----

@interface MactopLabelView : NSView
@property(strong, nonatomic) NSTextField *label;
@end

@implementation MactopLabelView
- (instancetype)initWithText:(NSString *)text
                        font:(NSFont *)font
                       color:(NSColor *)color {
  CGFloat chartW = (CGFloat)g_config.sparkline_width;
  CGFloat width = chartW + 16;
  CGFloat height = 20;
  self = [super initWithFrame:NSMakeRect(0, 0, width, height)];
  if (self) {
    _label = [NSTextField labelWithString:text];
    _label.font = font;
    _label.textColor = color;
    _label.frame = NSMakeRect(8, 0, width - 16, height);
    _label.drawsBackground = NO;
    _label.bordered = NO;
    _label.editable = NO;
    _label.selectable = NO;
    [self addSubview:_label];
  }
  return self;
}
@end

@interface MactopMetricView : NSView
@property(strong, nonatomic) NSTextField *labelField;
@property(strong, nonatomic) NSTextField *valueField;
@end

@implementation MactopMetricView
- (instancetype)initWithLabel:(NSString *)lbl value:(NSString *)val {
  CGFloat chartW = (CGFloat)g_config.sparkline_width;
  CGFloat width = chartW + 16;
  CGFloat height = 20;
  self = [super initWithFrame:NSMakeRect(0, 0, width, height)];
  if (self) {
    CGFloat halfW = (width - 16) / 2.0;

    // Label (Left)
    _labelField =
        [[NSTextField alloc] initWithFrame:NSMakeRect(8, 0, halfW, height)];
    _labelField.drawsBackground = NO;
    _labelField.bordered = NO;
    _labelField.editable = NO;
    _labelField.selectable = NO;
    _labelField.font = metricFont();
    _labelField.textColor = labelDimColor();
    _labelField.alignment = NSTextAlignmentLeft;

    // Value (Right)
    _valueField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(8 + halfW, 0, halfW, height)];
    _valueField.drawsBackground = NO;
    _valueField.bordered = NO;
    _valueField.editable = NO;
    _valueField.selectable = NO;
    _valueField.font = metricFont();
    _valueField.textColor = valueColor();
    _valueField.alignment = NSTextAlignmentRight;

    [self addSubview:_labelField];
    [self addSubview:_valueField];

    [self setTwoToneLabel:lbl value:val];
  }
  return self;
}

- (void)setTwoToneLabel:(NSString *)lbl value:(NSString *)val {
  _labelField.stringValue = lbl;
  _valueField.stringValue = val;
}
@end

@interface MactopImageView : NSView
@property(strong, nonatomic) NSImageView *imageView;
@end

@implementation MactopImageView
- (instancetype)initWithImage:(NSImage *)img {
  CGFloat insetX = 8; // match text item left/right padding
  CGFloat chartW = (CGFloat)g_config.sparkline_width;
  CGFloat h = (CGFloat)g_config.sparkline_height;
  CGFloat totalW = chartW + insetX * 2;
  self = [super initWithFrame:NSMakeRect(0, 0, totalW, h)];
  if (self) {
    _imageView =
        [[NSImageView alloc] initWithFrame:NSMakeRect(insetX, 0, chartW, h)];
    _imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _imageView.image = img;
    [self addSubview:_imageView];
  }
  return self;
}
@end

// ---- Delegate ----

@interface MactopMenuBarDelegate : NSObject <NSApplicationDelegate>
@property(strong, nonatomic) NSStatusItem *statusItem;
@property(strong, nonatomic) NSMenu *statusMenu;
@property(strong, nonatomic) NSMenuItem *modelItem;
@property(strong, nonatomic) NSMenuItem *cpuUsageItem;
@property(strong, nonatomic) NSMenuItem *cpuEClusterItem;
@property(strong, nonatomic) NSMenuItem *cpuPClusterItem;
@property(strong, nonatomic) NSMenuItem *cpuWattsItem;
@property(strong, nonatomic) NSMenuItem *cpuTempItem;
@property(strong, nonatomic) NSMenuItem *gpuUsageItem;
@property(strong, nonatomic) NSMenuItem *gpuWattsItem;
@property(strong, nonatomic) NSMenuItem *gpuTempItem;
@property(strong, nonatomic) NSMenuItem *gpuTflopsItem;
@property(strong, nonatomic) NSMenuItem *memUsageItem;
@property(strong, nonatomic) NSMenuItem *memSwapItem;
@property(strong, nonatomic) NSMenuItem *netItem;
@property(strong, nonatomic) NSMenuItem *rdmaItem;
@property(strong, nonatomic) NSMenuItem *diskItem;
@property(strong, nonatomic) NSMenuItem *powerTotalItem;
@property(strong, nonatomic) NSMenuItem *powerPackageItem;
@property(strong, nonatomic) NSMenuItem *powerCpuItem;
@property(strong, nonatomic) NSMenuItem *powerGpuItem;
@property(strong, nonatomic) NSMenuItem *powerAneItem;
@property(strong, nonatomic) NSMenuItem *powerDramItem;
@property(strong, nonatomic) NSMenuItem *thermalItem;
@property(strong, nonatomic) NSMenuItem *cpuSparkItem;
@property(strong, nonatomic) NSMenuItem *gpuSparkItem;
@property(strong, nonatomic) NSMenuItem *aneSparkItem;
@property(strong, nonatomic) NSMenuItem *memSparkItem;
- (void)performMetricUpdate:(NSValue *)val;
@end

@implementation MactopMenuBarDelegate

- (void)quitApp:(id)sender {
  (void)sender;
  [NSApp terminate:nil];
}

- (void)openTUI:(id)sender {
  (void)sender;
  NSString *processPath =
      [[NSProcessInfo processInfo] arguments].firstObject ?: @"mactop";
  NSString *script =
      [NSString stringWithFormat:@"tell application \"Terminal\"\n"
                                 @"  activate\n"
                                 @"  do script \"%@\"\n"
                                 @"end tell",
                                 processPath];
  NSAppleScript *appleScript = [[NSAppleScript alloc] initWithSource:script];
  [appleScript executeAndReturnError:nil];
}

- (void)openGitHub:(id)sender {
  (void)sender;
  [[NSWorkspace sharedWorkspace]
      openURL:[NSURL URLWithString:@"https://github.com/metaspartan/mactop"]];
}

// Settings toggles — persist after each change
- (void)toggleCPU:(NSMenuItem *)item {
  g_config.show_cpu = !g_config.show_cpu;
  item.state =
      g_config.show_cpu ? NSControlStateValueOn : NSControlStateValueOff;
  persistConfig();
}
- (void)toggleGPU:(NSMenuItem *)item {
  g_config.show_gpu = !g_config.show_gpu;
  item.state =
      g_config.show_gpu ? NSControlStateValueOn : NSControlStateValueOff;
  persistConfig();
}
- (void)toggleANE:(NSMenuItem *)item {
  g_config.show_ane = !g_config.show_ane;
  item.state =
      g_config.show_ane ? NSControlStateValueOn : NSControlStateValueOff;
  persistConfig();
}
- (void)toggleMemory:(NSMenuItem *)item {
  g_config.show_memory = !g_config.show_memory;
  item.state =
      g_config.show_memory ? NSControlStateValueOn : NSControlStateValueOff;
  persistConfig();
}
- (void)togglePower:(NSMenuItem *)item {
  g_config.show_power = !g_config.show_power;
  item.state =
      g_config.show_power ? NSControlStateValueOn : NSControlStateValueOff;
  persistConfig();
}
- (void)togglePercent:(NSMenuItem *)item {
  g_config.show_percent = !g_config.show_percent;
  item.state =
      g_config.show_percent ? NSControlStateValueOn : NSControlStateValueOff;
  persistConfig();
}

- (void)increaseBarWidth:(id)sender {
  g_config.status_bar_width += 4;
  if (g_config.status_bar_width > 120)
    g_config.status_bar_width = 120;
  persistConfig();
}

- (void)decreaseBarWidth:(id)sender {
  g_config.status_bar_width -= 4;
  if (g_config.status_bar_width < 16)
    g_config.status_bar_width = 16;
  persistConfig();
}

// Color picker actions
- (void)pickCPUColor:(NSMenuItem *)item {
  (void)item;
  [self showColorPanelForBar:@"cpu" current:cpuColor()];
}
- (void)pickGPUColor:(NSMenuItem *)item {
  (void)item;
  [self showColorPanelForBar:@"gpu" current:gpuColor()];
}
- (void)pickANEColor:(NSMenuItem *)item {
  (void)item;
  [self showColorPanelForBar:@"ane" current:aneColor()];
}
- (void)pickMemColor:(NSMenuItem *)item {
  (void)item;
  [self showColorPanelForBar:@"mem" current:memColor()];
}

- (void)showColorPanelForBar:(NSString *)bar current:(NSColor *)color {
  NSColorPanel *panel = [NSColorPanel sharedColorPanel];
  panel.color = color;
  panel.showsAlpha = NO;
  panel.title = [NSString
      stringWithFormat:@"mactop — %@ Bar Color", [bar uppercaseString]];

  // Use objc_setAssociatedObject to tag which bar
  objc_setAssociatedObject(panel, "mactop_bar", bar,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  // Observe color changes
  [[NSNotificationCenter defaultCenter]
      removeObserver:self
                name:NSColorPanelColorDidChangeNotification
              object:panel];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(colorDidChange:)
             name:NSColorPanelColorDidChangeNotification
           object:panel];

  [panel makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)colorDidChange:(NSNotification *)note {
  NSColorPanel *panel = note.object;
  NSString *bar = objc_getAssociatedObject(panel, "mactop_bar");
  NSColor *color = panel.color;
  NSString *hex = hexFromColor(color);
  const char *hexC = [hex UTF8String];

  if ([bar isEqualToString:@"cpu"]) {
    strlcpy(g_config.cpu_color, hexC, sizeof(g_config.cpu_color));
  } else if ([bar isEqualToString:@"gpu"]) {
    strlcpy(g_config.gpu_color, hexC, sizeof(g_config.gpu_color));
  } else if ([bar isEqualToString:@"ane"]) {
    strlcpy(g_config.ane_color, hexC, sizeof(g_config.ane_color));
  } else if ([bar isEqualToString:@"mem"]) {
    strlcpy(g_config.mem_color, hexC, sizeof(g_config.mem_color));
  }
  persistConfig();
}

- (void)performMetricUpdate:(NSValue *)val {
  menubar_metrics_t metrics;
  [val getValue:&metrics];
  [self doUpdate:&metrics];
}

- (void)doUpdate:(menubar_metrics_t *)mptr {
  menubar_metrics_t metrics = *mptr;

  pushHistory(cpuHistory, metrics.cpu_percent);
  pushHistory(gpuHistory, metrics.gpu_percent);
  pushHistory(aneHistory, metrics.ane_percent);
  double memPct = 0;
  if (metrics.mem_total_bytes > 0) {
    memPct = (double)metrics.mem_used_bytes / (double)metrics.mem_total_bytes *
             100.0;
  }
  pushHistory(memHistory, memPct);

  // Status bar icon
  self.statusItem.button.image = drawStatusBarImage(
      metrics.cpu_percent, metrics.gpu_percent, metrics.ane_percent, memPct);

  // Status bar title (power draw)
  if (g_config.show_power) {
    self.statusItem.button.title =
        [NSString stringWithFormat:@" %.1fW ", metrics.total_watts];
  } else {
    self.statusItem.button.title = @"";
  }

  // Model header
  MactopLabelView *mv = (MactopLabelView *)self.modelItem.view;
  mv.label.alignment = NSTextAlignmentCenter;
  mv.label.stringValue =
      [NSString stringWithFormat:@"%s  (%dE + %dP + %dGPU)", metrics.model_name,
                                 metrics.e_core_count, metrics.p_core_count,
                                 metrics.gpu_core_count];

  // CPU
  MactopMetricView *v = (MactopMetricView *)self.cpuUsageItem.view;
  [v setTwoToneLabel:@"Usage:"
               value:[NSString
                         stringWithFormat:@"%.1f%%", metrics.cpu_percent]];

  v = (MactopMetricView *)self.cpuEClusterItem.view;
  [v setTwoToneLabel:@"E-Cluster:"
               value:[NSString stringWithFormat:@"%d MHz (%.1f%%)",
                                                metrics.ecluster_freq_mhz,
                                                metrics.ecluster_active]];

  v = (MactopMetricView *)self.cpuPClusterItem.view;
  [v setTwoToneLabel:@"P-Cluster:"
               value:[NSString stringWithFormat:@"%d MHz (%.1f%%)",
                                                metrics.pcluster_freq_mhz,
                                                metrics.pcluster_active]];

  v = (MactopMetricView *)self.cpuWattsItem.view;
  [v setTwoToneLabel:@"Power:"
               value:[NSString stringWithFormat:@"%.2f W", metrics.cpu_watts]];

  v = (MactopMetricView *)self.cpuTempItem.view;
  [v setTwoToneLabel:@"Temp:"
               value:[NSString stringWithFormat:@"%.1f°C", metrics.cpu_temp]];

  // GPU
  v = (MactopMetricView *)self.gpuUsageItem.view;
  [v setTwoToneLabel:@"Usage:"
               value:[NSString stringWithFormat:@"%.1f%% (%d MHz)",
                                                metrics.gpu_percent,
                                                metrics.gpu_freq_mhz]];

  v = (MactopMetricView *)self.gpuWattsItem.view;
  [v setTwoToneLabel:@"Power:"
               value:[NSString stringWithFormat:@"%.2f W", metrics.gpu_watts]];

  double activeTF = (metrics.gpu_percent / 100.0) * metrics.tflops_fp32;
  v = (MactopMetricView *)self.gpuTflopsItem.view;
  [v setTwoToneLabel:@"TFLOPs:"
               value:[NSString stringWithFormat:@"%.2f / %.2f FP32", activeTF,
                                                metrics.tflops_fp32]];

  v = (MactopMetricView *)self.gpuTempItem.view;
  [v setTwoToneLabel:@"Temp:"
               value:[NSString stringWithFormat:@"%.1f°C", metrics.gpu_temp]];

  // Memory — display GB
  double memUsedGB =
      (double)metrics.mem_used_bytes / (1024.0 * 1024.0 * 1024.0);
  double memTotalGB =
      (double)metrics.mem_total_bytes / (1024.0 * 1024.0 * 1024.0);
  v = (MactopMetricView *)self.memUsageItem.view;
  [v setTwoToneLabel:@"RAM:"
               value:[NSString stringWithFormat:@"%.1f / %.0f GB (%.1f%%)",
                                                memUsedGB, memTotalGB, memPct]];

  double swapUsedGB =
      (double)metrics.swap_used_bytes / (1024.0 * 1024.0 * 1024.0);
  double swapTotalGB =
      (double)metrics.swap_total_bytes / (1024.0 * 1024.0 * 1024.0);
  v = (MactopMetricView *)self.memSwapItem.view;
  [v setTwoToneLabel:@"Swap:"
               value:[NSString stringWithFormat:@"%.1f / %.1f GB", swapUsedGB,
                                                swapTotalGB]];

  // Network
  v = (MactopMetricView *)self.netItem.view;
  [v setTwoToneLabel:@"Network:"
               value:[NSString
                         stringWithFormat:@"↓ %@  ↑ %@",
                                          formatThroughput(
                                              metrics.net_in_bytes_per_sec),
                                          formatThroughput(
                                              metrics.net_out_bytes_per_sec)]];

  v = (MactopMetricView *)self.rdmaItem.view;
  [v setTwoToneLabel:@"RDMA:"
               value:[NSString stringWithUTF8String:metrics.rdma_status]];

  // Disk
  v = (MactopMetricView *)self.diskItem.view;
  [v setTwoToneLabel:@"Disk:"
               value:[NSString stringWithFormat:@"R %.0f KB/s  W %.0f KB/s",
                                                metrics.disk_read_kb_per_sec,
                                                metrics.disk_write_kb_per_sec]];

  // Power
  v = (MactopMetricView *)self.powerTotalItem.view;
  [v setTwoToneLabel:@"Total:"
               value:[NSString
                         stringWithFormat:@"%.2f W", metrics.total_watts]];
  v = (MactopMetricView *)self.powerPackageItem.view;
  [v setTwoToneLabel:@"System:"
               value:[NSString
                         stringWithFormat:@"%.2f W", metrics.package_watts]];
  v = (MactopMetricView *)self.powerCpuItem.view;
  [v setTwoToneLabel:@"CPU:"
               value:[NSString stringWithFormat:@"%.2f W", metrics.cpu_watts]];
  v = (MactopMetricView *)self.powerGpuItem.view;
  [v setTwoToneLabel:@"GPU:"
               value:[NSString stringWithFormat:@"%.2f W", metrics.gpu_watts]];
  v = (MactopMetricView *)self.powerAneItem.view;
  [v setTwoToneLabel:@"ANE:"
               value:[NSString stringWithFormat:@"%.2f W", metrics.ane_watts]];
  v = (MactopMetricView *)self.powerDramItem.view;
  [v setTwoToneLabel:@"DRAM:"
               value:[NSString stringWithFormat:@"%.2f W", metrics.dram_watts]];
  v = (MactopMetricView *)self.thermalItem.view;
  [v setTwoToneLabel:@"Thermal:"
               value:[NSString stringWithUTF8String:metrics.thermal_state]];

  // Sparklines
  MactopImageView *iv = (MactopImageView *)self.cpuSparkItem.view;
  iv.imageView.image =
      drawSparklineChart(cpuHistory, SPARKLINE_HISTORY_SIZE, cpuColor(), @"CPU",
                         metrics.cpu_percent, nil);
  iv = (MactopImageView *)self.gpuSparkItem.view;
  iv.imageView.image =
      drawSparklineChart(gpuHistory, SPARKLINE_HISTORY_SIZE, gpuColor(), @"GPU",
                         metrics.gpu_percent, nil);
  iv = (MactopImageView *)self.aneSparkItem.view;
  iv.imageView.image =
      drawSparklineChart(aneHistory, SPARKLINE_HISTORY_SIZE, aneColor(), @"ANE",
                         metrics.ane_percent, nil);

  // MEM sparkline — show GB instead of %
  NSString *memValStr =
      [NSString stringWithFormat:@"%.1f / %.0f GB", memUsedGB, memTotalGB];
  iv = (MactopImageView *)self.memSparkItem.view;
  iv.imageView.image =
      drawSparklineChart(memHistory, SPARKLINE_HISTORY_SIZE, memColor(), @"MEM",
                         memPct, memValStr);
}

@end

static MactopMenuBarDelegate *g_delegate = nil;

// ---- Typography ----

static NSFont *metricFont(void) {
  return [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
}

static NSFont *headerFont(void) {
  return [NSFont systemFontOfSize:13 weight:NSFontWeightHeavy];
}

// Create view-backed menu items
static NSMenuItem *makeHeaderItem(NSString *title) {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@""
                                                action:nil
                                         keyEquivalent:@""];
  MactopLabelView *view = [[MactopLabelView alloc] initWithText:title
                                                           font:headerFont()
                                                          color:headerColor()];
  item.view = view;
  return item;
}

static NSMenuItem *makeMetricItem(NSString *label, NSString *value) {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@""
                                                action:nil
                                         keyEquivalent:@""];
  MactopMetricView *view = [[MactopMetricView alloc] initWithLabel:label
                                                             value:value];
  item.view = view;
  return item;
}

static NSMenuItem *makeSparkItem(NSImage *img) {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@""
                                                action:nil
                                         keyEquivalent:@""];
  MactopImageView *view = [[MactopImageView alloc] initWithImage:img];
  item.view = view;
  return item;
}

// Branding header: "mactop" bold white
static NSMenuItem *makeBrandingItem(void) {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@""
                                                action:nil
                                         keyEquivalent:@""];
  CGFloat chartW = (CGFloat)g_config.sparkline_width;
  CGFloat width = chartW + 16;
  CGFloat height = 22;
  NSView *container =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];

  NSTextField *field =
      [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
  field.drawsBackground = NO;
  field.bordered = NO;
  field.editable = NO;
  field.selectable = NO;
  field.alignment = NSTextAlignmentCenter;

  NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
  style.alignment = NSTextAlignmentCenter;

  NSMutableAttributedString *as = [[NSMutableAttributedString alloc] init];
  [as appendAttributedString:[[NSAttributedString alloc]
                                 initWithString:@"mactop"
                                     attributes:@{
                                       NSFontAttributeName : [NSFont
                                           systemFontOfSize:14
                                                     weight:NSFontWeightHeavy],
                                       NSForegroundColorAttributeName :
                                           [NSColor whiteColor],
                                       NSParagraphStyleAttributeName : style
                                     }]];
  field.attributedStringValue = as;
  [container addSubview:field];
  item.view = container;
  return item;
}

// ---- Status Bar Drawing (Horizontal side-by-side bars) ----

static void drawHBar(NSString *label, double pct, NSColor *color, CGFloat x,
                     CGFloat barY, CGFloat barW, CGFloat barH,
                     int showPercent) {
  CGFloat fill = (pct / 100.0) * barW;
  if (fill < 1.0 && pct > 0)
    fill = 1.0;

  NSFont *lf = [NSFont monospacedDigitSystemFontOfSize:7
                                                weight:NSFontWeightBold];
  NSDictionary *la = @{
    NSFontAttributeName : lf,
    NSForegroundColorAttributeName : [NSColor colorWithWhite:1.0 alpha:0.9]
  };
  NSSize ls = [label sizeWithAttributes:la];
  CGFloat labelW = ls.width + 2;
  CGFloat ly = barY + (barH - ls.height) / 2.0;
  [label drawAtPoint:NSMakePoint(x, ly) withAttributes:la];

  CGFloat bx = x + labelW;

  // Track
  [[NSColor colorWithWhite:1.0 alpha:0.15] set];
  NSBezierPath *track =
      [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, barY, barW, barH)
                                      xRadius:2
                                      yRadius:2];
  [track fill];

  // Fill
  if (fill > 0) {
    [color set];
    NSBezierPath *bar =
        [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, barY, fill, barH)
                                        xRadius:2
                                        yRadius:2];
    [bar fill];
  }

  // Percentage Text (if enabled)
  if (showPercent) {
    NSFont *pf = [NSFont monospacedDigitSystemFontOfSize:9
                                                  weight:NSFontWeightRegular];
    NSDictionary *pa = @{
      NSFontAttributeName : pf,
      NSForegroundColorAttributeName : [NSColor whiteColor]
    };
    NSString *pStr = [NSString stringWithFormat:@"%.0f%%", pct];
    CGFloat px = bx + barW + 2;
    CGFloat py = barY + (barH - [pStr sizeWithAttributes:pa].height) / 2.0 - 1;
    [pStr drawAtPoint:NSMakePoint(px, py) withAttributes:pa];
  }
}

static NSImage *drawStatusBarImage(double cpu, double gpu, double ane,
                                   double memPct) {
  int barCount = 0;
  if (g_config.show_cpu)
    barCount++;
  if (g_config.show_gpu)
    barCount++;
  if (g_config.show_ane)
    barCount++;
  if (g_config.show_memory)
    barCount++;
  if (barCount == 0) {
    NSImage *empty = [[NSImage alloc] initWithSize:NSMakeSize(1, 18)];
    [empty setTemplate:NO];
    return empty;
  }

  CGFloat barH = 8, gap = 2, labelExtra = 10;
  CGFloat barW = (CGFloat)g_config.status_bar_width;

  // If showing percent, add specific space for "100%" (~24px)
  CGFloat percentExtra = g_config.show_percent ? 24.0 : 0.0;

  CGFloat sectionW = labelExtra + barW + percentExtra;
  // Reduce gap if percentages are shown since they have their own spacing
  if (g_config.show_percent)
    gap = 4; // Explicit gap between sections

  CGFloat totalW = barCount * sectionW + (barCount - 1) * gap + 4;
  CGFloat h = 18;

  NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(totalW, h)];
  [img lockFocus];

  CGFloat barY = (h - barH) / 2.0;
  CGFloat x = 2;

  if (g_config.show_cpu) {
    drawHBar(@"C", cpu, cpuColor(), x, barY, barW, barH, g_config.show_percent);
    x += sectionW + gap;
  }
  if (g_config.show_gpu) {
    drawHBar(@"G", gpu, gpuColor(), x, barY, barW, barH, g_config.show_percent);
    x += sectionW + gap;
  }
  if (g_config.show_ane) {
    drawHBar(@"A", ane, aneColor(), x, barY, barW, barH, g_config.show_percent);
    x += sectionW + gap;
  }
  if (g_config.show_memory) {
    drawHBar(@"M", memPct, memColor(), x, barY, barW, barH,
             g_config.show_percent);
  }

  [img unlockFocus];
  [img setTemplate:NO];
  return img;
}

// ---- Sparkline Chart Drawing ----

static NSImage *drawSparklineChart(double *history, int count, NSColor *color,
                                   NSString *label, double currentVal,
                                   NSString *valOverride) {
  CGFloat w = (CGFloat)g_config.sparkline_width;
  CGFloat h = (CGFloat)g_config.sparkline_height;

  NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
  [img lockFocus];

  CGFloat padL = 4, padR = 4, padT = 16, padB = 4;
  CGFloat chartW = w - padL - padR;
  CGFloat chartH = h - padT - padB;

  // Transparent background

  double maxVal = 100.0;

  // Subtle grid lines
  [[NSColor colorWithWhite:1.0 alpha:0.08] set];
  for (int g = 1; g <= 3; g++) {
    CGFloat gy = padB + (chartH * (CGFloat)g / 4.0);
    NSBezierPath *gridLine = [NSBezierPath bezierPath];
    [gridLine moveToPoint:NSMakePoint(padL, gy)];
    [gridLine lineToPoint:NSMakePoint(padL + chartW, gy)];
    [gridLine setLineWidth:0.5];
    [gridLine stroke];
  }

  CGFloat barW = chartW / (CGFloat)count;

  // Filled gradient area
  NSBezierPath *areaPath = [NSBezierPath bezierPath];
  [areaPath moveToPoint:NSMakePoint(padL, padB)];
  for (int i = 0; i < count; i++) {
    CGFloat bh = (history[i] / maxVal) * chartH;
    CGFloat bx = padL + (CGFloat)i * barW;
    [areaPath lineToPoint:NSMakePoint(bx, padB + bh)];
    [areaPath lineToPoint:NSMakePoint(bx + barW, padB + bh)];
  }
  [areaPath lineToPoint:NSMakePoint(padL + chartW, padB)];
  [areaPath closePath];

  NSGradient *gradient = [[NSGradient alloc]
      initWithStartingColor:[color colorWithAlphaComponent:0.5]
                endingColor:[color colorWithAlphaComponent:0.1]];
  [gradient drawInBezierPath:areaPath angle:90];

  // Edge line
  NSBezierPath *linePath = [NSBezierPath bezierPath];
  [linePath setLineWidth:1.5];
  for (int i = 0; i < count; i++) {
    CGFloat bh = (history[i] / maxVal) * chartH;
    CGFloat bx = padL + (CGFloat)i * barW;
    CGFloat by = padB + bh;
    if (i == 0)
      [linePath moveToPoint:NSMakePoint(bx, by)];
    else
      [linePath lineToPoint:NSMakePoint(bx, by)];
    [linePath lineToPoint:NSMakePoint(bx + barW, by)];
  }
  [color set];
  [linePath stroke];

  // Label (colored, left)
  NSFont *labelFont = [NSFont systemFontOfSize:10 weight:NSFontWeightBold];
  NSDictionary *labelAttrs = @{
    NSFontAttributeName : labelFont,
    NSForegroundColorAttributeName : color
  };
  [label drawAtPoint:NSMakePoint(padL + 2, h - padT + 2)
      withAttributes:labelAttrs];

  // Value (white, right) — use override if provided
  NSString *valStr =
      valOverride ?: [NSString stringWithFormat:@"%.1f%%", currentVal];
  NSFont *valFont = [NSFont monospacedDigitSystemFontOfSize:11
                                                     weight:NSFontWeightBold];
  NSDictionary *valAttrs = @{
    NSFontAttributeName : valFont,
    NSForegroundColorAttributeName : [NSColor whiteColor]
  };
  NSSize valSize = [valStr sizeWithAttributes:valAttrs];
  [valStr drawAtPoint:NSMakePoint(w - padR - valSize.width - 2, h - padT + 2)
       withAttributes:valAttrs];

  [img unlockFocus];
  [img setTemplate:NO];
  return img;
}

static NSString *formatThroughput(double bps) {
  if (bps >= 1024 * 1024 * 1024)
    return [NSString stringWithFormat:@"%.1f GB/s", bps / (1024 * 1024 * 1024)];
  if (bps >= 1024 * 1024)
    return [NSString stringWithFormat:@"%.1f MB/s", bps / (1024 * 1024)];
  if (bps >= 1024)
    return [NSString stringWithFormat:@"%.1f KB/s", bps / 1024];
  return [NSString stringWithFormat:@"%.0f B/s", bps];
}

// ---- Persist config back to Go ----

static void persistConfig(void) {
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        GoSaveMenuBarConfig(
            g_config.status_bar_width, g_config.show_cpu, g_config.show_gpu,
            g_config.show_ane, g_config.show_memory, g_config.show_power,
            g_config.show_percent, g_config.cpu_color, g_config.gpu_color,
            g_config.ane_color, g_config.mem_color);
      });
}

// ---- Lifecycle ----

void setMenuBarConfig(menubar_config_t *cfg) {
  if (cfg)
    g_config = *cfg;
}

static void buildMenu(void) {
  @autoreleasepool {
    NSStatusBar *statusBar = [NSStatusBar systemStatusBar];
    g_delegate.statusItem =
        [statusBar statusItemWithLength:NSVariableStatusItemLength];

    NSStatusBarButton *button = g_delegate.statusItem.button;
    button.title = @" mactop ";
    button.toolTip = @"mactop \u2014 Apple Silicon Monitor";
    button.font = [NSFont monospacedDigitSystemFontOfSize:11
                                                   weight:NSFontWeightMedium];
    button.imagePosition = NSImageLeading;

    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;

    // --- Branding ---
    [menu addItem:makeBrandingItem()];
    [menu addItem:[NSMenuItem separatorItem]];

    // --- Model ---
    g_delegate.modelItem = makeHeaderItem(@"Apple Silicon");
    [menu addItem:g_delegate.modelItem];
    [menu addItem:[NSMenuItem separatorItem]];

    // --- CPU ---
    [menu addItem:makeHeaderItem(@"CPU")];
    g_delegate.cpuUsageItem = makeMetricItem(@"Usage:", @"\u2014");
    [menu addItem:g_delegate.cpuUsageItem];
    g_delegate.cpuEClusterItem = makeMetricItem(@"E-Cluster:", @"\u2014");
    [menu addItem:g_delegate.cpuEClusterItem];
    g_delegate.cpuPClusterItem = makeMetricItem(@"P-Cluster:", @"\u2014");
    [menu addItem:g_delegate.cpuPClusterItem];
    g_delegate.cpuWattsItem = makeMetricItem(@"Power:", @"\u2014");
    [menu addItem:g_delegate.cpuWattsItem];
    g_delegate.cpuTempItem = makeMetricItem(@"Temp:", @"\u2014");
    [menu addItem:g_delegate.cpuTempItem];
    [menu addItem:[NSMenuItem separatorItem]];

    // --- GPU ---
    [menu addItem:makeHeaderItem(@"GPU")];
    g_delegate.gpuUsageItem = makeMetricItem(@"Usage:", @"\u2014");
    [menu addItem:g_delegate.gpuUsageItem];
    g_delegate.gpuWattsItem = makeMetricItem(@"Power:", @"\u2014");
    [menu addItem:g_delegate.gpuWattsItem];
    g_delegate.gpuTflopsItem = makeMetricItem(@"TFLOPs:", @"\u2014");
    [menu addItem:g_delegate.gpuTflopsItem];
    g_delegate.gpuTempItem = makeMetricItem(@"Temp:", @"\u2014");
    [menu addItem:g_delegate.gpuTempItem];
    [menu addItem:[NSMenuItem separatorItem]];

    // --- Memory ---
    [menu addItem:makeHeaderItem(@"MEMORY")];
    g_delegate.memUsageItem = makeMetricItem(@"RAM:", @"\u2014");
    [menu addItem:g_delegate.memUsageItem];
    g_delegate.memSwapItem = makeMetricItem(@"Swap:", @"\u2014");
    [menu addItem:g_delegate.memSwapItem];
    [menu addItem:[NSMenuItem separatorItem]];

    // --- Network ---
    [menu addItem:makeHeaderItem(@"NETWORK")];
    g_delegate.netItem = makeMetricItem(@"Network:", @"\u2014");
    [menu addItem:g_delegate.netItem];
    g_delegate.rdmaItem = makeMetricItem(@"RDMA:", @"\u2014");
    [menu addItem:g_delegate.rdmaItem];
    [menu addItem:[NSMenuItem separatorItem]];

    // --- Disk ---
    [menu addItem:makeHeaderItem(@"DISK")];
    g_delegate.diskItem = makeMetricItem(@"Disk:", @"\u2014");
    [menu addItem:g_delegate.diskItem];
    [menu addItem:[NSMenuItem separatorItem]];

    // --- Power ---
    [menu addItem:makeHeaderItem(@"POWER")];
    g_delegate.powerTotalItem = makeMetricItem(@"Total:", @"\u2014");
    [menu addItem:g_delegate.powerTotalItem];
    g_delegate.powerPackageItem = makeMetricItem(@"System:", @"\u2014");
    [menu addItem:g_delegate.powerPackageItem];
    g_delegate.powerCpuItem = makeMetricItem(@"CPU:", @"\u2014");
    [menu addItem:g_delegate.powerCpuItem];
    g_delegate.powerGpuItem = makeMetricItem(@"GPU:", @"\u2014");
    [menu addItem:g_delegate.powerGpuItem];
    g_delegate.powerAneItem = makeMetricItem(@"ANE:", @"\u2014");
    [menu addItem:g_delegate.powerAneItem];
    g_delegate.powerDramItem = makeMetricItem(@"DRAM:", @"\u2014");
    [menu addItem:g_delegate.powerDramItem];
    g_delegate.thermalItem = makeMetricItem(@"Thermal:", @"\u2014");
    [menu addItem:g_delegate.thermalItem];
    [menu addItem:[NSMenuItem separatorItem]];

    // --- History (sparklines) ---
    [menu addItem:makeHeaderItem(@"HISTORY")];

    NSImage *emptySparkCPU = drawSparklineChart(
        cpuHistory, SPARKLINE_HISTORY_SIZE, cpuColor(), @"CPU", 0, nil);
    g_delegate.cpuSparkItem = makeSparkItem(emptySparkCPU);
    [menu addItem:g_delegate.cpuSparkItem];

    NSImage *emptySparkGPU = drawSparklineChart(
        gpuHistory, SPARKLINE_HISTORY_SIZE, gpuColor(), @"GPU", 0, nil);
    g_delegate.gpuSparkItem = makeSparkItem(emptySparkGPU);
    [menu addItem:g_delegate.gpuSparkItem];

    NSImage *emptySparkANE = drawSparklineChart(
        aneHistory, SPARKLINE_HISTORY_SIZE, aneColor(), @"ANE", 0, nil);
    g_delegate.aneSparkItem = makeSparkItem(emptySparkANE);
    [menu addItem:g_delegate.aneSparkItem];

    NSImage *emptySparkMEM =
        drawSparklineChart(memHistory, SPARKLINE_HISTORY_SIZE, memColor(),
                           @"MEM", 0, @"0.0 / 0 GB");
    g_delegate.memSparkItem = makeSparkItem(emptySparkMEM);
    [menu addItem:g_delegate.memSparkItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // --- Settings submenu ---
    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings"
                                                          action:nil
                                                   keyEquivalent:@""];
    NSMenu *settingsMenu = [[NSMenu alloc] init];

    // Visibility toggles
    NSMenuItem *cpuToggle =
        [[NSMenuItem alloc] initWithTitle:@"Show CPU Bar"
                                   action:@selector(toggleCPU:)
                            keyEquivalent:@""];
    cpuToggle.target = g_delegate;
    cpuToggle.state =
        g_config.show_cpu ? NSControlStateValueOn : NSControlStateValueOff;
    [settingsMenu addItem:cpuToggle];

    NSMenuItem *gpuToggle =
        [[NSMenuItem alloc] initWithTitle:@"Show GPU Bar"
                                   action:@selector(toggleGPU:)
                            keyEquivalent:@""];
    gpuToggle.target = g_delegate;
    gpuToggle.state =
        g_config.show_gpu ? NSControlStateValueOn : NSControlStateValueOff;
    [settingsMenu addItem:gpuToggle];

    NSMenuItem *aneToggle =
        [[NSMenuItem alloc] initWithTitle:@"Show ANE Bar"
                                   action:@selector(toggleANE:)
                            keyEquivalent:@""];
    aneToggle.target = g_delegate;
    aneToggle.state =
        g_config.show_ane ? NSControlStateValueOn : NSControlStateValueOff;
    [settingsMenu addItem:aneToggle];

    NSMenuItem *memToggle =
        [[NSMenuItem alloc] initWithTitle:@"Show Memory Bar"
                                   action:@selector(toggleMemory:)
                            keyEquivalent:@""];
    memToggle.target = g_delegate;
    memToggle.state =
        g_config.show_memory ? NSControlStateValueOn : NSControlStateValueOff;
    [settingsMenu addItem:memToggle];

    [settingsMenu addItem:[NSMenuItem separatorItem]];

    // Width controls
    NSMenuItem *widthUp =
        [[NSMenuItem alloc] initWithTitle:@"Increase Bar Width (+)"
                                   action:@selector(increaseBarWidth:)
                            keyEquivalent:@"+"];
    widthUp.target = g_delegate;
    [settingsMenu addItem:widthUp];

    NSMenuItem *widthDown =
        [[NSMenuItem alloc] initWithTitle:@"Decrease Bar Width (-)"
                                   action:@selector(decreaseBarWidth:)
                            keyEquivalent:@"-"];
    widthDown.target = g_delegate;
    [settingsMenu addItem:widthDown];

    [settingsMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *powerToggle =
        [[NSMenuItem alloc] initWithTitle:@"Show Wattage"
                                   action:@selector(togglePower:)
                            keyEquivalent:@""];
    powerToggle.target = g_delegate;
    powerToggle.state =
        g_config.show_power ? NSControlStateValueOn : NSControlStateValueOff;
    [settingsMenu addItem:powerToggle];

    NSMenuItem *percentToggle =
        [[NSMenuItem alloc] initWithTitle:@"Show Percentages"
                                   action:@selector(togglePercent:)
                            keyEquivalent:@""];
    percentToggle.target = g_delegate;
    percentToggle.state =
        g_config.show_percent ? NSControlStateValueOn : NSControlStateValueOff;
    [settingsMenu addItem:percentToggle];

    [settingsMenu addItem:[NSMenuItem separatorItem]];

    // Color picker items
    NSMenuItem *cpuColorItem =
        [[NSMenuItem alloc] initWithTitle:@"CPU Bar Color…"
                                   action:@selector(pickCPUColor:)
                            keyEquivalent:@""];
    cpuColorItem.target = g_delegate;
    [settingsMenu addItem:cpuColorItem];

    NSMenuItem *gpuColorItem =
        [[NSMenuItem alloc] initWithTitle:@"GPU Bar Color…"
                                   action:@selector(pickGPUColor:)
                            keyEquivalent:@""];
    gpuColorItem.target = g_delegate;
    [settingsMenu addItem:gpuColorItem];

    NSMenuItem *aneColorItem =
        [[NSMenuItem alloc] initWithTitle:@"ANE Bar Color…"
                                   action:@selector(pickANEColor:)
                            keyEquivalent:@""];
    aneColorItem.target = g_delegate;
    [settingsMenu addItem:aneColorItem];

    NSMenuItem *memColorItem =
        [[NSMenuItem alloc] initWithTitle:@"Memory Bar Color…"
                                   action:@selector(pickMemColor:)
                            keyEquivalent:@""];
    memColorItem.target = g_delegate;
    [settingsMenu addItem:memColorItem];

    settingsItem.submenu = settingsMenu;
    [menu addItem:settingsItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // --- Actions ---
    NSMenuItem *ghItem =
        [[NSMenuItem alloc] initWithTitle:@"Open GitHub Info\u2026"
                                   action:@selector(openGitHub:)
                            keyEquivalent:@""];
    ghItem.target = g_delegate;
    [menu addItem:ghItem];

    NSMenuItem *tuiItem =
        [[NSMenuItem alloc] initWithTitle:@"Open mactop TUI\u2026"
                                   action:@selector(openTUI:)
                            keyEquivalent:@"t"];
    tuiItem.target = g_delegate;
    [menu addItem:tuiItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit mactop"
                                                      action:@selector(quitApp:)
                                               keyEquivalent:@"q"];
    quitItem.target = g_delegate;
    [menu addItem:quitItem];

    g_delegate.statusMenu = menu;
    g_delegate.statusItem.menu = menu;
  }
}

// Initialize menu bar on the MAIN thread. Does not block.
int startMenuBarInBackground(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    g_delegate = [[MactopMenuBarDelegate alloc] init];
    [NSApp setDelegate:g_delegate];

    buildMenu();
    [NSApp finishLaunching];

    return 0;
  }
}

// Blocking initializer (for standalone --menubar without TUI)
int initMenuBar(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    g_delegate = [[MactopMenuBarDelegate alloc] init];
    [NSApp setDelegate:g_delegate];

    buildMenu();
    return 0;
  }
}

void updateMenuBarMetrics(menubar_metrics_t *m) {
  if (g_delegate == nil || m == NULL)
    return;

  menubar_metrics_t copy = *m;
  NSValue *val = [NSValue valueWithBytes:&copy
                                objCType:@encode(menubar_metrics_t)];
  dispatch_async(dispatch_get_main_queue(), ^{
    [g_delegate performMetricUpdate:val];
  });
}

// Non-blocking pump: drain any pending AppKit events (for TUI+menubar mode)
void pumpMenuBarEvents(void) {
  @autoreleasepool {
    NSEvent *event;
    while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                       untilDate:nil
                                          inMode:NSDefaultRunLoopMode
                                         dequeue:YES])) {
      [NSApp sendEvent:event];
    }
  }
}

void runMenuBarLoop(void) { [NSApp run]; }

void cleanupMenuBar(void) {
  if (g_delegate != nil) {
    if (g_delegate.statusItem != nil) {
      [[NSStatusBar systemStatusBar] removeStatusItem:g_delegate.statusItem];
      g_delegate.statusItem = nil;
    }
    g_delegate = nil;
  }
}
