# Adds the HoshiReaderTests unit-test bundle (hosted by the app) to the project and to the
# shared scheme's Test action. Idempotent: re-running is a no-op once the target exists.
require 'xcodeproj'

PROJECT = 'Hoshi Reader.xcodeproj'
TARGET_NAME = 'HoshiReaderTests'
project = Xcodeproj::Project.open(PROJECT)
app = project.targets.find { |t| t.name == 'Hoshi Reader' } or abort('app target not found')

test_target = project.targets.find { |t| t.name == TARGET_NAME }
unless test_target
  test_target = project.new_target(:unit_test_bundle, TARGET_NAME, :ios, '18.6')
  test_target.add_dependency(app)
  group = project.main_group.find_subpath('Tests/Integration', true)
  group.set_source_tree('<group>')
  group.set_path('Tests/Integration')
  Dir.glob('Tests/Integration/*.swift').sort.each do |path|
    ref = group.new_file(File.basename(path))
    test_target.add_file_references([ref])
  end
  test_target.build_configurations.each do |config|
    s = config.build_settings
    s['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Hoshi Reader.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Hoshi Reader'
    s['BUNDLE_LOADER'] = '$(TEST_HOST)'
    s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.dragosristache.hoshi.HoshiReaderTests'
    s['PRODUCT_NAME'] = '$(TARGET_NAME)'
    s['SWIFT_VERSION'] = '6.0'
    s['SWIFT_DEFAULT_ACTOR_ISOLATION'] = 'MainActor'
    s['SWIFT_APPROACHABLE_CONCURRENCY'] = 'YES'
    s['SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY'] = 'YES'
    s['GENERATE_INFOPLIST_FILE'] = 'YES'
    s['CODE_SIGN_STYLE'] = 'Automatic'
    s['DEVELOPMENT_TEAM'] = 'XR83Z84FJZ'
    s['IPHONEOS_DEPLOYMENT_TARGET'] = '18.6'
    s['TARGETED_DEVICE_FAMILY'] = '1,2'
    s['SWIFT_EMIT_LOC_STRINGS'] = 'NO'
    s['CURRENT_PROJECT_VERSION'] = '1'
    s['MARKETING_VERSION'] = '1.0'
  end
  project.save
  puts "added target #{TARGET_NAME}"
else
  puts "target #{TARGET_NAME} already present"
end

# `@testable import Hoshi_Reader` compiles the app module's interface, which references the
# hoshidicts C++ clang module; the test target must therefore build with the same C++ interop
# and search-path settings as the app. Mirrored on every run so the two never drift.
MIRRORED = %w[
  SWIFT_OBJC_INTEROP_MODE OTHER_SWIFT_FLAGS CLANG_CXX_LANGUAGE_STANDARD CLANG_CXX_LIBRARY
  HEADER_SEARCH_PATHS SWIFT_INCLUDE_PATHS SWIFT_STRICT_CONCURRENCY GCC_PREPROCESSOR_DEFINITIONS
]
test_target.build_configurations.each do |config|
  source = app.build_configurations.find { |c| c.name == config.name } or next
  MIRRORED.each do |key|
    value = source.build_settings[key]
    if value.nil?
      config.build_settings.delete(key)
    else
      config.build_settings[key] = value
    end
  end
end
project.save

scheme_path = Xcodeproj::XCScheme.shared_data_dir(PROJECT) + 'Hoshi Reader.xcscheme'
scheme = Xcodeproj::XCScheme.new(scheme_path)
already = scheme.test_action.testables.any? { |t| t.buildable_references.any? { |r| r.target_name == TARGET_NAME } }
unless already
  scheme.add_test_target(test_target)
  scheme.save!
  puts 'added test target to the shared scheme'
else
  puts 'scheme already tests the target'
end
