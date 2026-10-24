Pod::Spec.new do |s|
  s.name          = 'MiniwallCore'
  s.version       = '0.1.1'
  s.summary       = 'Miniwall screen model, layout engine and logic (pure Swift), shared by MiniwallSDK.'
  s.homepage      = 'https://docs.miniwall.app'
  s.license       = { :type => 'MIT' }
  s.author        = 'Miniwall'
  s.source        = { :git => 'https://github.com/miniwall-app/miniwall-ios.git', :tag => s.version.to_s }
  s.ios.deployment_target = '16.0'
  s.swift_version = '5.9'
  s.source_files  = 'Sources/MiniwallCore/**/*.swift'
end
