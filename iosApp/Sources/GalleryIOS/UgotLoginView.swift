import SwiftUI

struct UgotLoginView: View {
  @ObservedObject var authViewModel: UgotAuthViewModel

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color.indigo.opacity(0.22), Color.blue.opacity(0.14), Color(.systemBackground)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(spacing: 22) {
        VStack(spacing: 12) {
          Image(systemName: "sparkles")
            .font(.system(size: 48, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 88, height: 88)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
          Text("Sign in to UGOT Chat")
            .font(.largeTitle.bold())
            .multilineTextAlignment(.center)
          Text("Use native Google sign-in to keep chat, MCP tools, and model downloads tied to your UGOT session.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }

        if let errorMessage = authViewModel.errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }

        Button {
          Task { await authViewModel.signIn() }
        } label: {
          HStack(spacing: 10) {
            if authViewModel.isLoading {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "g.circle.fill")
            }
            Text(authViewModel.isLoading ? "Signing in…" : "Continue with Google")
              .font(.headline)
          }
          .frame(maxWidth: .infinity)
          .padding()
          .foregroundStyle(.white)
          .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(authViewModel.isLoading)
      }
      .padding(24)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
      .padding(24)
    }
  }
}
