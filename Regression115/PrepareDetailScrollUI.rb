# CI-only: generate an XCTest UI target around the real application project.
# Production sources are used unchanged except a local launch destination and
# an accessibility identifier in this disposable checkout. No forum writes.
require 'xcodeproj'
app_path = 'SeHuaTang/SeHuaTangApp.swift'
app = File.read(app_path)
app.sub!('RootView()', 'NavigationStack { ThreadDetailView(tid: 79, title: "SCROLL TOP", sourceURL: URL(string: "http://127.0.0.1:18766/forum.php?mod=viewthread&tid=79&page=1")!) }.background { HiddenWebView().frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false) }')
File.write(app_path, app)
view_path = 'SeHuaTang/Views/ThreadDetailView.swift'
view = File.read(view_path)
needle = 'SelectableDetailText(text: NSAttributedString(string: d.title.isEmpty ? title : d.title, attributes: [.font: UIFont.preferredFont(forTextStyle: .headline)]), onLink: openBodyLink)'
raise 'title instrumentation anchor missing' unless view.include?(needle)
view.sub!(needle, needle + "\n                    .accessibilityIdentifier(\"detail-scroll-title\")")
File.write(view_path, view)
p = Xcodeproj::Project.open('SeHuaTang.xcodeproj')
app_target = p.targets.find { |t| t.name == 'SeHuaTang' }
tests = p.new_target(:ui_test_bundle, 'DetailScrollUITests', :ios, '17.0')
tests.add_dependency(app_target)
ref = p.main_group.new_file('Regression115/DetailScrollUITests.swift')
tests.source_build_phase.add_file_reference(ref)
tests.build_configurations.each do |c|
  c.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  c.build_settings['PRODUCT_MODULE_NAME'] = 'DetailScrollUITests'
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.sehuatang.scrolltests'
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  c.build_settings['TEST_TARGET_NAME'] = 'SeHuaTang'
  c.build_settings['SWIFT_VERSION'] = '5.0'
  c.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
end
p.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.add_build_target(tests)
scheme.add_test_target(tests)
scheme.set_launch_target(app_target)
scheme.save_as('SeHuaTang.xcodeproj', 'DetailScroll', true)
