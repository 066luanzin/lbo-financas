import SwiftUI
import SwiftData
import Observation
import UserNotifications

/// Estado compartilhado entre telas e com as ações do app Atalhos
@MainActor
@Observable
final class AppState {
    static let shared = AppState()
    var abrirRegistro = false
    var tourPasso: Int? = nil
    var bloqueado = UserDefaults.standard.bool(forKey: "faceID")
    var abrirRevisao = false
    var abrirFechamento: Int? = nil

    struct Desfazer {
        let id = UUID()
        let texto: String
        let acao: () -> Void
    }
    /// Última exclusão que ainda dá pra desfazer (some sozinha depois de alguns segundos)
    var desfazer: Desfazer?

    func oferecerDesfazer(_ texto: String, _ acao: @escaping () -> Void) {
        let d = Desfazer(texto: texto, acao: acao)
        desfazer = d
        Task {
            try? await Task.sleep(for: .seconds(7))
            if desfazer?.id == d.id { desfazer = nil }
        }
    }
}

/// Barrinha "Conta apagada · Desfazer"
struct BarraDesfazer: View {
    @Environment(AppState.self) private var estado

    var body: some View {
        if let d = estado.desfazer {
            HStack(spacing: 12) {
                Image(systemName: "trash").foregroundStyle(.secondary)
                Text(d.texto).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer()
                Button("Desfazer") {
                    d.acao()
                    withAnimation { estado.desfazer = nil }
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.sobreDestaque)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Color.destaque, in: Capsule())
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(height: 50)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.borda))
            .padding(.horizontal, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifDelegate()
    // Mostra o aviso ("R$ 20,00 registrado") mesmo com o app aberto
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // Toque no aviso ou no botão "Paguei"
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let acao = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        await MainActor.run { Notificacoes.tratar(acao: acao, info: info) }
    }
}

@main
struct LBOApp: App {
    @State private var sessao = Sessao()
    @State private var estado = AppState.shared
    @AppStorage("tema") private var tema = "sistema"

    init() {
        UNUserNotificationCenter.current().delegate = NotifDelegate.shared
        Notificacoes.registrarCategorias()
    }

    private var esquema: ColorScheme? {
        switch tema {
        case "claro": return .light
        case "escuro": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RaizView()
                .environment(sessao)
                .environment(estado)
                .preferredColorScheme(esquema)
                .tint(.primary)
        }
    }
}

struct RaizView: View {
    @Environment(Sessao.self) private var sessao

    var body: some View {
        Group {
            if let uid = sessao.uid {
                UsuarioView(uid: uid)
                    .modelContainer(Store.container(uid))
                    .id(uid)
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: sessao.uid)
    }
}

/// Tudo que aparece depois do login: boas-vindas (1ª vez), app e bloqueio com Face ID
struct UsuarioView: View {
    let uid: String
    @Environment(AppState.self) private var estado
    @Environment(\.scenePhase) private var fase
    @Environment(\.modelContext) private var ctx
    @AppStorage private var onboardingFeito: Bool
    @AppStorage("faceID") private var faceID = false

    init(uid: String) {
        self.uid = uid
        _onboardingFeito = AppStorage(wrappedValue: false, "onboarding-" + uid)
    }

    var body: some View {
        ZStack {
            if onboardingFeito {
                MainView()
            } else {
                OnboardingView { withAnimation { onboardingFeito = true } }
            }
            if estado.bloqueado && faceID {
                TelaBloqueio { desbloquear() }
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .task {
            if onboardingFeito,
               await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined {
                _ = await Notificacoes.pedirPermissao()
            }
            Recorrencias.gerar(ctx)
            Migracao.saldoAcumulado(ctx)
            Migracao.bancos(ctx)
            Notificacoes.reagendar(ctx)
            if estado.bloqueado && faceID { desbloquear() }
            // iPhone novo (sem nada salvo): traz os dados do backup na nuvem
            if !Backup.temDadosLocais(ctx), let linha = try? await Backup.baixar(),
               !linha.dados.transacoes.isEmpty || !linha.dados.contas.isEmpty {
                Backup.aplicar(linha.dados, ctx: ctx)
                UserDefaults.standard.set(true, forKey: "tourFeito")
                withAnimation { onboardingFeito = true }
                Notificacoes.agora("Seus dados voltaram", "Recuperamos o backup da sua conta.")
            } else {
                await Backup.enviar(ctx)
            }
        }
        .onChange(of: fase) { _, nova in
            switch nova {
            case .background:
                if faceID { estado.bloqueado = true }
                Notificacoes.reagendar(ctx)
                Task { await Backup.enviar(ctx) }
            case .active:
                if estado.bloqueado && faceID { desbloquear() }
                Recorrencias.gerar(ctx)
            default:
                break
            }
        }
    }

    private func desbloquear() {
        Task {
            if await Biometria.autenticar() {
                withAnimation { estado.bloqueado = false }
            }
        }
    }
}

struct TelaBloqueio: View {
    var desbloquear: () -> Void
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            LogoView(tamanho: 96)
            Text("LBO FINANÇAS").font(.system(size: 13, weight: .medium)).tracking(5).foregroundStyle(.secondary)
            Spacer()
            Button {
                desbloquear()
            } label: {
                Label("Desbloquear", systemImage: "faceid")
            }
            .buttonStyle(EstiloPrincipal())
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.fundo.ignoresSafeArea())
    }
}
