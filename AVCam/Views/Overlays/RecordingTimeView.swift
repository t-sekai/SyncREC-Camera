/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A view that displays the current recording time.
*/

import SwiftUI

/// A view that displays the current recording time.
struct RecordingTimeView: PlatformView {

    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    
    let time: TimeInterval
    let tentacleTimecode: String
    let recordingTimecode: String
    
    var body: some View {
        Text(displayText)
            .padding([.leading, .trailing], 12)
            .padding([.top, .bottom], isRegularSize ? 8 : 0)
            .background(Color(white: 0.0, opacity: 0.5))
            .foregroundColor(.white)
            .font(.title2.weight(.semibold))
            .clipShape(.capsule)
    }

    private var displayText: String {
        if !recordingTimecode.isEmpty {
            return recordingTimecode
        }
        guard !tentacleTimecode.isEmpty else { return time.formatted }
        return tentacleTimecodeWithoutFrames
    }

    private var tentacleTimecodeWithoutFrames: String {
        let components = tentacleTimecode.split(separator: ":")
        guard components.count == 4 else { return tentacleTimecode }
        return components.prefix(3).joined(separator: ":")
    }
}

extension TimeInterval {
    var formatted: String {
        let time = Int(self)
        let seconds = time % 60
        let minutes = (time / 60) % 60
        let hours = (time / 3600)
        let formatString = "%0.2d:%0.2d:%0.2d"
        return String(format: formatString, hours, minutes, seconds)
    }
}

#if DEBUG
#Preview {
    RecordingTimeView(time: TimeInterval(floatLiteral: 500),
                      tentacleTimecode: "01:02:03",
                      recordingTimecode: "")
        .background(Image("video_mode"))
}
#endif
