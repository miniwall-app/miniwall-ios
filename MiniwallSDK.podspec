# CocoaPods (React Native, Flutter, CocoaPods apps); Swift Package Manager users pick the MiniwallSDK product.
# Paths are relative to this folder: use it with :path until the pods are published (phase 9).
#   pod 'MiniwallCore', :path => '<miniwall-ios checkout>'
#   pod 'MiniwallSDK', :path => '<miniwall-ios checkout>'
Pod::Spec.new do |s|
  s.name          = 'MiniwallSDK'
  s.version       = '0.1.1'
  s.summary       = 'Show paywalls, onboarding and offers built in the Miniwall dashboard, rendered natively in SwiftUI.'
  s.homepage      = 'https://docs.miniwall.app'
  s.license       = { :type => 'MIT' }
  s.author        = 'Miniwall'
  s.source        = { :git => 'https://github.com/miniwall-app/miniwall-ios.git', :tag => s.version.to_s }
  s.ios.deployment_target = '16.0'
  s.swift_version = '5.9'
  s.source_files  = 'Sources/MiniwallSDK/**/*.swift'
  s.resource_bundles = { 'MiniwallSDK' => ['Sources/MiniwallSDK/PrivacyInfo.xcprivacy'] }
  s.dependency 'MiniwallCore', s.version.to_s
  s.frameworks    = 'SwiftUI', 'UIKit', 'AVFoundation', 'StoreKit'
end
