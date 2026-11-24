import SwiftUI

struct LoginView: View {
    enum Etapa { case entrar, criar, codigo, recuperar, novaSenha }

    @Environment(Sessao.self) private var sessao
    @State private var etapa: Etapa = .entrar
    @State private var nome = ""
    @State private var email = ""
    @State private var senha = ""
    @State private var senha2 = ""
    @State private var codigo = ""
    @State private var carregando = false
    @State private var erro: String?
    @State private var aviso: String?
    @State private var espera = 0

    private var emailLimpo: String { email.trimmingCharacters(in: .whitespaces).lowercased() }
    private var emailValido: Bool { emailLimpo.contains("@") && emailLimpo.contains(".") }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                LogoView(tamanho: 110)
                    .padding(.top, 50)
                Text("LBO FINANÇAS")
                    .font(.system(size: 13, weight: .medium)).tracking(5)
                    .foregroundStyle(.secondary)
                    .padding(.top, 26)

                conteudo
                    .padding(.top, 34)

                if let erro {
                    Text(erro)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                }
                if let aviso, erro == nil {
                    Text(aviso)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.fundo.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: etapa)
        .task(id: espera) {
            if espera > 0 {
                try? await Task.sleep(for: .seconds(1))
                espera -= 1
            }
        }
    }

    @ViewBuilder
    private var conteudo: some View {
        switch etapa {
        case .entrar: telaEntrar
        case .criar: telaCriar
        case .codigo: telaCodigo
        case .recuperar: telaRecuperar
        case .novaSenha: telaNovaSenha
        }
    }

    // MARK: Entrar

    private var telaEntrar: some View {
        VStack(spacing: 14) {
            titulos("Bem-vindo", "Entre para continuar")
            TextField("seu@email.com", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .campo()
            CampoSenha(placeholder: "Senha", texto: $senha)
            HStack {
                Spacer()
                Button("Esqueci minha senha") { trocar(.recuperar) }
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button {
                entrar()
            } label: {
                HStack(spacing: 10) {
                    if carregando { ProgressView() } else { Text("Entrar"); Image(systemName: "arrow.right") }
                }
            }
            .buttonStyle(EstiloContorno(ativo: emailValido && senha.count >= 6))
            .disabled(!emailValido || senha.count < 6 || carregando)
            .padding(.top, 18)
            HStack(spacing: 4) {
                Text("Não tem conta?").foregroundStyle(.secondary)
                Button("Criar conta") { trocar(.criar) }.fontWeight(.semibold)
            }
            .font(.subheadline)
        }
    }

    // MARK: Criar conta

    private var telaCriar: some View {
        let valido = !nome.trimmingCharacters(in: .whitespaces).isEmpty && emailValido && senha.count >= 6 && senha == senha2
        return VStack(spacing: 14) {
            titulos("Criar conta", "Vamos te mandar um código no e-mail")
            TextField("Seu nome", text: $nome)
                .textContentType(.name)
                .campo()
            TextField("seu@email.com", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .campo()
            CampoSenha(placeholder: "Senha (mínimo 6 caracteres)", texto: $senha, nova: true)
            CampoSenha(placeholder: "Repita a senha", texto: $senha2, nova: true)
            if !senha2.isEmpty && senha != senha2 {
                Text("As senhas não são iguais.").font(.footnote).foregroundStyle(.red)
            }
            Button {
                criar()
            } label: {
                if carregando { ProgressView() } else { Text("Enviar código") }
            }
            .buttonStyle(EstiloPrincipal(ativo: valido))
            .disabled(!valido || carregando)
            .padding(.top, 14)
            botaoVoltar
        }
    }

    // MARK: Código de confirmação

    private var telaCodigo: some View {
        VStack(spacing: 14) {
            titulos("Confirme seu e-mail", "Digite o código que enviamos para\n\(emailLimpo)")
            CampoCodigo(codigo: $codigo)
            Button {
                executar {
                    try await sessao.confirmarCadastro(email: emailLimpo, codigo: codigo)
                }
            } label: {
                if carregando { ProgressView() } else { Text("Confirmar") }
            }
            .buttonStyle(EstiloPrincipal(ativo: codigo.count >= 6))
            .disabled(codigo.count < 6 || carregando)
            .padding(.top, 10)
            Button(espera > 0 ? "Reenviar código em \(espera)s" : "Reenviar código") {
                executar {
                    try await sessao.reenviarCodigo(email: emailLimpo)
                    aviso = "Enviamos um novo código."
                    espera = 60
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .disabled(espera > 0)
            botaoVoltar
        }
    }

    // MARK: Recuperar senha

    private var telaRecuperar: some View {
        VStack(spacing: 14) {
            titulos("Esqueci minha senha", "Vamos te mandar um código pra criar uma senha nova")
            TextField("seu@email.com", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .campo()
            Button {
                executar {
                    try await sessao.recuperarSenha(email: emailLimpo)
                    codigo = ""
                    senha = ""
                    senha2 = ""
                    etapa = .novaSenha
                    aviso = "Se existir uma conta com esse e-mail, o código chega em instantes."
                }
            } label: {
                if carregando { ProgressView() } else { Text("Enviar código") }
            }
            .buttonStyle(EstiloPrincipal(ativo: emailValido))
            .disabled(!emailValido || carregando)
            .padding(.top, 10)
            botaoVoltar
        }
    }

    private var telaNovaSenha: some View {
        let valido = codigo.count >= 6 && senha.count >= 6 && senha == senha2
        return VStack(spacing: 14) {
            titulos("Nova senha", "Digite o código do e-mail e a senha nova")
            CampoCodigo(codigo: $codigo)
            CampoSenha(placeholder: "Senha nova", texto: $senha, nova: true)
            CampoSenha(placeholder: "Repita a senha nova", texto: $senha2, nova: true)
            Button {
                executar {
                    try await sessao.trocarSenha(email: emailLimpo, codigo: codigo, novaSenha: senha)
                }
            } label: {
                if carregando { ProgressView() } else { Text("Salvar e entrar") }
            }
            .buttonStyle(EstiloPrincipal(ativo: valido))
            .disabled(!valido || carregando)
            .padding(.top, 10)
            botaoVoltar
        }
    }

    // MARK: Partes

    private func titulos(_ titulo: String, _ sub: String) -> some View {
        VStack(spacing: 8) {
            Text(titulo).font(.system(size: 29, weight: .heavy)).tracking(-1)
            Text(sub).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.bottom, 16)
    }

    private var botaoVoltar: some View {
        Button("Voltar para o login") { trocar(.entrar) }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    private func trocar(_ nova: Etapa) {
        erro = nil
        aviso = nil
        codigo = ""
        if nova == .entrar || nova == .criar { senha = ""; senha2 = "" }
        etapa = nova
    }

    private func entrar() {
        executar {
            do {
                try await sessao.entrar(email: emailLimpo, senha: senha)
            } catch {
                guard Sessao.naoConfirmado(error) else { throw error }
                try? await sessao.reenviarCodigo(email: emailLimpo)
                codigo = ""
                etapa = .codigo
                aviso = "Sua conta ainda não foi confirmada. Enviamos um código."
                espera = 60
            }
        }
    }

    private func criar() {
        executar {
            let entrou = try await sessao.criarConta(nome: nome.trimmingCharacters(in: .whitespaces), email: emailLimpo, senha: senha)
            if entrou { return }
            codigo = ""
            etapa = .codigo
            aviso = nil
            espera = 60
        }
    }

    private func executar(_ acao: @escaping () async throws -> Void) {
        erro = nil
        carregando = true
        Task {
            do { try await acao() } catch { erro = Sessao.mensagem(error) }
            carregando = false
        }
    }
}

struct CampoSenha: View {
    let placeholder: String
    @Binding var texto: String
    var nova = false
    @State private var mostrar = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if mostrar {
                    TextField(placeholder, text: $texto)
                } else {
                    SecureField(placeholder, text: $texto)
                }
            }
            .textContentType(nova ? .newPassword : .password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .campo()

            Button { mostrar.toggle() } label: {
                Image(systemName: mostrar ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 58, height: 58)
                    .background(Color.cartao2.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.borda))
            }
            .buttonStyle(.plain)
        }
    }
}

struct CampoCodigo: View {
    @Binding var codigo: String
    @FocusState private var foco: Bool

    var body: some View {
        TextField("000000", text: $codigo)
            .font(.system(size: 27, weight: .bold, design: .monospaced))
            .tracking(8)
            .multilineTextAlignment(.center)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($foco)
            .frame(height: 72)
            .background(Color.cartao2.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.borda))
            .onChange(of: codigo) { _, novo in
                let limpo = String(novo.filter(\.isNumber).prefix(8))
                if limpo != novo { codigo = limpo }
            }
            .onAppear { foco = true }
    }
}
