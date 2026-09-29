Pod::Spec.new do |s|
  s.name                = 'applooma_rtc'
  s.version             = '0.3.10'
  s.summary             = 'AppLooma RTC Flutter SDK: Video Enhance and Clear Voice on iOS.'
  s.description         = 'Native capture processing for the AppLooma RTC Flutter SDK.'
  s.homepage            = 'https://applooma.dev'
  s.license             = { :file => '../LICENSE' }
  s.author              = { 'AppLooma LLC' => 'support@applooma.dev' }
  s.source              = { :path => '.' }
  s.source_files        = 'applooma_rtc/Sources/applooma_rtc/**/*.{h,m}'
  s.public_header_files = 'applooma_rtc/Sources/applooma_rtc/include/**/*.h'
  s.platform            = :ios, '13.0'
  s.frameworks          = 'CoreImage', 'CoreVideo'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.static_framework    = true

  s.dependency 'Flutter'
  s.dependency 'flutter_webrtc'
  s.dependency 'WebRTC-SDK'
end
