import Foundation
import Observation
import Supabase

/// Login, cadastro com código no e-mail e recuperação de senha (Supabase Auth).
/// Depois de entrar, o app funciona offline: o usuário logado fica salvo no iPhone.
@MainActor
@Observable
final class Sessao {
    var uid: String? = UserDefaults.standard.string(forKey: "uidAtual")

    let client = Nuvem.client

    func entrar(email: String, senha: String) async throws {
        let s = try await client.auth.signIn(email: email, password: senha)
        registrar(s.user, nome: nil)
    }

    /// Devolve true quando o servidor já entra direto (confirmação de e-mail desligada no Supabase).
    func criarConta(nome: String, email: String, senha: String) async throws -> Bool {
        let r = try await client.auth.signUp(email: email, password: senha, data: ["nome": .string(nome)])
        if r.session != nil {
            registrar(r.user, nome: nome)
            return true
        }
        UserDefaults.standard.set(nome, forKey: "nomePendente")
        return false
    }

    func confirmarCadastro(email: String, codigo: String) async throws {
        let r = try await client.auth.verifyOTP(email: email, token: codigo, type: .signup)
        registrar(r.user, nome: UserDefaults.standard.string(forKey: "nomePendente"))
    }

    func reenviarCodigo(email: String) async throws {
        try await client.auth.resend(email: email, type: .signup)
    }

    func recuperarSenha(email: String) async throws {
        try await client.auth.resetPasswordForEmail(email)
    }

    func trocarSenha(email: String, codigo: String, novaSenha: String) async throws {
        let r = try await client.auth.verifyOTP(email: email, token: codigo, type: .recovery)
        _ = try await client.auth.update(user: UserAttributes(password: novaSenha))
        registrar(r.user, nome: nil)
    }

    func sair() async {
        try? await client.auth.signOut()
        UserDefaults.standard.removeObject(forKey: "uidAtual")
        uid = nil
    }

    func excluirConta() async throws {
        try await client.rpc("excluir_conta").execute()
        let atual = uid
        await sair()
        if let atual { Store.apagar(atual) }
    }

    private func registrar(_ user: User, nome: String?) {
        let d = UserDefaults.standard
        var n = nome ?? ""
        if n.isEmpty, case let .string(s)? = user.userMetadata["nome"] { n = s }
        d.set(user.id.uuidString, forKey: "uidAtual")
        d.set(user.email ?? "", forKey: "emailUsuario")
        if !n.isEmpty { d.set(n, forKey: "nomeUsuario") }
        d.removeObject(forKey: "nomePendente")
        uid = user.id.uuidString
    }

    static func naoConfirmado(_ error: Error) -> Bool {
        texto(error).contains("not confirmed")
    }

    static func mensagem(_ error: Error) -> String {
        let t = texto(error)
        if t.contains("invalid login") || t.contains("invalid_credentials") { return "E-mail ou senha incorretos." }
        if t.contains("already registered") || t.contains("user_already_exists") { return "Já existe uma conta com esse e-mail." }
        if t.contains("expired") || t.contains("invalid") && t.contains("token") || t.contains("otp") {
            return "Código inválido ou vencido. Peça um novo."
        }
        if t.contains("rate limit") || t.contains("too many") || t.contains("over_email_send_rate_limit") {
            return "Muitas tentativas. Espere alguns minutos e tente de novo."
        }
        if t.contains("password") && (t.contains("6") || t.contains("weak")) { return "A senha precisa ter pelo menos 6 caracteres." }
        if t.contains("offline") || t.contains("network") || t.contains("internet") || t.contains("timed out") {
            return "Sem conexão com a internet."
        }
        if t.contains("sessao_backup") { return "Sua conta precisa ser confirmada de novo: toque em Sair e entre de novo. Seus dados continuam no iPhone." }
        if t.contains("excluir_conta") { return "Exclusão de conta ainda não configurada no servidor." }
        if t.contains("backups") && (t.contains("does not exist") || t.contains("42p01") || t.contains("schema cache")) {
            return "O backup ainda não foi configurado no servidor (falta rodar o SQL do backup)."
        }
        if t.contains("row-level security") || t.contains("42501") || t.contains("permission denied") {
            return "Sem permissão no servidor. Confira o SQL do backup."
        }
        if t.contains("jwt") || t.contains("not authenticated") || t.contains("session") {
            return "Sua sessão expirou. Saia e entre de novo na conta."
        }
        return "Algo deu errado. Tente de novo."
    }

    private static func texto(_ error: Error) -> String {
        (String(describing: error) + " " + error.localizedDescription).lowercased()
    }
}
