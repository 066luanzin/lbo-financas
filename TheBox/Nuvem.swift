import Foundation
import SwiftData
import CryptoKit
import UIKit
import Supabase

/// Cliente único do Supabase (login e backup usam o mesmo)
enum Nuvem {
    static let client = SupabaseClient(
        supabaseURL: Configuracao.supabaseURL, supabaseKey: Configuracao.supabaseChave,
        options: SupabaseClientOptions(auth: .init(storage: SessaoNoAparelho()))
    )
}

/// Guarda o login da nuvem nos arquivos do app em vez do chaveiro: quando o SideStore reinstala
/// com outro certificado, o chaveiro some e o backup parava com "sem permissão"; aqui o login fica.
struct SessaoNoAparelho: AuthLocalStorage {
    private let d = UserDefaults.standard
    private func k(_ key: String) -> String { "sessaoNuvem." + key }
    func store(key: String, value: Data) throws { d.set(value, forKey: k(key)) }
    func retrieve(key: String) throws -> Data? { d.data(forKey: k(key)) }
    func remove(key: String) throws { d.removeObject(forKey: k(key)) }
}

/// Cópia de tudo que o usuário tem no app, guardada na tabela "backups" do Supabase
struct BackupDados: Codable {
    var versao = 1
    var transacoes: [T]
    var contas: [C]
    var categorias: [Cat]
    var carteiras: [Cart]
    var limites: [L]
    var preferencias: [String: String]
    var recorrencias: [R]? = nil
    var caixinhas: [Cx]? = nil

    struct R: Codable {
        var nome: String
        var valor: Double
        var dia: Int
        var categoria: String
        var carteira: String
        var ultimoMes: Int
        var ativa: Bool
        var chave: String? = nil
    }
    struct Cx: Codable {
        var nome: String
        var meta: Double
        var saldoInicial: Double
        var prazo: Double?
        var ordem: Int
        var chave: String? = nil
    }

    struct T: Codable {
        var tipo: String
        var valor: Double
        var categoria: String
        var carteira: String
        var descricao: String
        var data: Double
        var entrada: Bool? = nil
        var destino: String? = nil
        var chave: String? = nil
    }
    struct C: Codable {
        var nome: String
        var valor: Double
        var dia: Int
        var venceMesSeguinte: Bool
        var categoria: String
        var repetir: Bool
        var parcelaAtual: Int
        var totalParcelas: Int
        var inicio: Int
        var pagamentos: [String]
        var excluidos: [String]
        var adiantadas: Int
        var juros: Double
        var fim: Int?
        var chave: String? = nil
    }
    struct Cat: Codable {
        var nome: String
        var icone: String
        var tipo: String
        var limite: Double
        var essencial: Bool
        var ordem: Int
        var chave: String? = nil
    }
    struct Cart: Codable {
        var nome: String
        var tipo: String
        var diaVencimento: Int
        var diaFechamento: Int
        var ordem: Int
        var faturasPagas: [String]
        var chave: String? = nil
    }
    struct L: Codable {
        var mes: Int
        var valor: Double
    }
}

enum ErroBackup: Error, LocalizedError {
    case semSessao
    var errorDescription: String? { "sessao_backup" }
}

struct LinhaBackup: Codable {
    var user_id: String
    var dados: BackupDados
    var atualizado_em: String
}

@MainActor
enum Backup {
    private static let preferenciasTexto = ["nomeUsuario", "diasAviso", "moeda", "tema", "objetivo", "metodoQuitacao"]

    static var ultimo: Date? { UserDefaults.standard.object(forKey: "ultimoBackup") as? Date }

    static func temDadosLocais(_ ctx: ModelContext) -> Bool {
        ((try? ctx.fetchCount(FetchDescriptor<Transacao>())) ?? 0) > 0
            || ((try? ctx.fetchCount(FetchDescriptor<Conta>())) ?? 0) > 0
    }

    static func montar(_ ctx: ModelContext) -> BackupDados {
        let ts = (try? ctx.fetch(FetchDescriptor<Transacao>())) ?? []
        let cs = (try? ctx.fetch(FetchDescriptor<Conta>())) ?? []
        let cats = (try? ctx.fetch(FetchDescriptor<Categoria>())) ?? []
        let carts = (try? ctx.fetch(FetchDescriptor<Carteira>())) ?? []
        let ls = (try? ctx.fetch(FetchDescriptor<LimiteMensal>())) ?? []
        let d = UserDefaults.standard
        var prefs: [String: String] = [:]
        for k in preferenciasTexto { if let v = d.string(forKey: k) { prefs[k] = v } }
        if let renda = d.object(forKey: "renda") as? Double { prefs["renda"] = String(renda) }
        prefs["orcAtivo"] = d.bool(forKey: "orcAtivo") ? "1" : "0"
        prefs["orcModo"] = d.string(forKey: "orcModo") ?? "dia"
        prefs["orcSemana"] = String(d.double(forKey: "orcSemana"))
        prefs["orcDias"] = OrcamentoDia.porDia.map { String($0) }.joined(separator: ",")
        return BackupDados(
            transacoes: ts.sorted { $0.data < $1.data }.map {
                .init(tipo: $0.tipoRaw, valor: $0.valor, categoria: $0.categoria, carteira: $0.carteira,
                      descricao: $0.descricao, data: $0.data.timeIntervalSince1970, entrada: $0.entrada,
                      destino: $0.destino.isEmpty ? nil : $0.destino, chave: $0.chave.uuidString)
            },
            contas: cs.sorted { $0.nome < $1.nome }.map {
                .init(nome: $0.nome, valor: $0.valor, dia: $0.dia, venceMesSeguinte: $0.venceMesSeguinte,
                      categoria: $0.categoria, repetir: $0.repetir, parcelaAtual: $0.parcelaAtual,
                      totalParcelas: $0.totalParcelas, inicio: $0.inicio, pagamentos: $0.pagamentos,
                      excluidos: $0.excluidos, adiantadas: $0.adiantadas, juros: $0.juros, fim: $0.fim,
                      chave: $0.chave.uuidString)
            },
            categorias: cats.sorted { $0.ordem < $1.ordem }.map {
                .init(nome: $0.nome, icone: $0.icone, tipo: $0.tipoRaw, limite: $0.limite,
                      essencial: $0.essencial, ordem: $0.ordem, chave: $0.chave.uuidString)
            },
            carteiras: carts.sorted { $0.ordem < $1.ordem }.map {
                .init(nome: $0.nome, tipo: $0.tipoRaw, diaVencimento: $0.diaVencimento,
                      diaFechamento: $0.diaFechamento, ordem: $0.ordem, faturasPagas: $0.faturasPagas,
                      chave: $0.chave.uuidString)
            },
            limites: ls.sorted { $0.mes < $1.mes }.map { .init(mes: $0.mes, valor: $0.valor) },
            preferencias: prefs,
            recorrencias: ((try? ctx.fetch(FetchDescriptor<Recorrencia>())) ?? []).map {
                .init(nome: $0.nome, valor: $0.valor, dia: $0.dia, categoria: $0.categoria, carteira: $0.carteira,
                      ultimoMes: $0.ultimoMes, ativa: $0.ativa, chave: $0.chave.uuidString)
            },
            caixinhas: ((try? ctx.fetch(FetchDescriptor<Caixinha>())) ?? []).map {
                .init(nome: $0.nome, meta: $0.meta, saldoInicial: $0.saldoInicial,
                      prazo: $0.prazo?.timeIntervalSince1970, ordem: $0.ordem, chave: $0.chave.uuidString)
            }
        )
    }

    /// Troca tudo que está no iPhone pelo que veio do backup
    static func aplicar(_ b: BackupDados, ctx: ModelContext) {
        try? ctx.delete(model: Transacao.self)
        try? ctx.delete(model: Conta.self)
        try? ctx.delete(model: Categoria.self)
        try? ctx.delete(model: Carteira.self)
        try? ctx.delete(model: LimiteMensal.self)
        try? ctx.delete(model: Recorrencia.self)
        try? ctx.delete(model: Caixinha.self)
        for t in b.transacoes {
            let nova = Transacao(tipo: TipoTransacao(rawValue: t.tipo) ?? .gasto, valor: t.valor, categoria: t.categoria,
                                 carteira: t.carteira, descricao: t.descricao,
                                 data: Date(timeIntervalSince1970: t.data), entrada: t.entrada ?? false)
            nova.destino = t.destino ?? ""
            if let k = t.chave.flatMap(UUID.init(uuidString:)) { nova.chave = k }
            ctx.insert(nova)
        }
        for c in b.contas {
            let nova = Conta(nome: c.nome, valor: c.valor, dia: c.dia, venceMesSeguinte: c.venceMesSeguinte,
                             categoria: c.categoria, repetir: c.repetir, parcelaAtual: c.parcelaAtual,
                             totalParcelas: c.totalParcelas, inicio: c.inicio)
            nova.pagamentos = c.pagamentos
            nova.excluidos = c.excluidos
            nova.adiantadas = c.adiantadas
            nova.juros = c.juros
            nova.fim = c.fim ?? 0
            if let k = c.chave.flatMap(UUID.init(uuidString:)) { nova.chave = k }
            ctx.insert(nova)
        }
        for c in b.categorias {
            let nova = Categoria(nome: c.nome, icone: c.icone, tipo: TipoTransacao(rawValue: c.tipo) ?? .gasto,
                                 limite: c.limite, essencial: c.essencial, ordem: c.ordem)
            if let k = c.chave.flatMap(UUID.init(uuidString:)) { nova.chave = k }
            ctx.insert(nova)
        }
        for c in b.carteiras {
            let nova = Carteira(nome: c.nome, tipo: TipoCarteira(rawValue: c.tipo) ?? .credito,
                                diaVencimento: c.diaVencimento, ordem: c.ordem)
            nova.diaFechamento = c.diaFechamento
            nova.faturasPagas = c.faturasPagas
            if let k = c.chave.flatMap(UUID.init(uuidString:)) { nova.chave = k }
            ctx.insert(nova)
        }
        for l in b.limites { ctx.insert(LimiteMensal(mes: l.mes, valor: l.valor)) }
        for r in b.recorrencias ?? [] {
            let nova = Recorrencia(nome: r.nome, valor: r.valor, dia: r.dia, categoria: r.categoria,
                                   carteira: r.carteira, ultimoMes: r.ultimoMes)
            nova.ativa = r.ativa
            if let k = r.chave.flatMap(UUID.init(uuidString:)) { nova.chave = k }
            ctx.insert(nova)
        }
        for c in b.caixinhas ?? [] {
            let nova = Caixinha(nome: c.nome, meta: c.meta, saldoInicial: c.saldoInicial,
                                prazo: c.prazo.map { Date(timeIntervalSince1970: $0) }, ordem: c.ordem)
            if let k = c.chave.flatMap(UUID.init(uuidString:)) { nova.chave = k }
            ctx.insert(nova)
        }
        try? ctx.save()
        let d = UserDefaults.standard
        for (k, v) in b.preferencias {
            switch k {
            case "renda", "orcSemana": d.set(Double(v) ?? 0, forKey: k)
            case "orcAtivo": d.set(v == "1", forKey: k)
            case "orcDias": d.set(v.split(separator: ",").map { Double($0) ?? 0 }, forKey: k)
            default: d.set(v, forKey: k)
            }
        }
        Store.semear(ctx)
        Notificacoes.reagendar(ctx)
    }

    /// Envia o backup se algo mudou desde o último (ou sempre, se forcar = true)
    @discardableResult
    static func enviar(_ ctx: ModelContext, forcar: Bool = false) async -> String? {
        guard let uid = UserDefaults.standard.string(forKey: "uidAtual") else { return "Entre na sua conta primeiro." }
        let dados = montar(ctx)
        guard let json = try? JSONEncoder().encode(dados) else { return "Não foi possível montar o backup." }
        let hash = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
        let d = UserDefaults.standard
        if !forcar && hash == d.string(forKey: "backupHash") { return nil }
        guard await temSessao() else {
            let msg = semSessao
            d.set(msg, forKey: "erroBackup")
            return msg
        }

        // dá uns segundos a mais pro envio terminar quando o app vai pro fundo
        let tarefa = UIApplication.shared.beginBackgroundTask(withName: "backup")
        defer { if tarefa != .invalid { UIApplication.shared.endBackgroundTask(tarefa) } }
        do {
            let linha = LinhaBackup(user_id: uid.lowercased(), dados: dados,
                                    atualizado_em: ISO8601DateFormatter().string(from: .now))
            try await Nuvem.client.from("backups").upsert(linha, onConflict: "user_id").execute()
            d.set(hash, forKey: "backupHash")
            d.set(Date.now, forKey: "ultimoBackup")
            d.removeObject(forKey: "erroBackup")
            return nil
        } catch {
            let msg = Sessao.mensagem(error)
            d.set(msg, forKey: "erroBackup")
            return msg
        }
    }

    static let semSessao = "Sua conta precisa ser confirmada de novo pra usar o backup: toque em Sair (em Conta, aqui embaixo) e entre de novo. Seus dados continuam no iPhone."

    /// Login ainda válido no servidor? (se o app foi reinstalado, o iPhone pode ter apagado)
    static func temSessao() async -> Bool {
        (try? await Nuvem.client.auth.session) != nil
    }

    static func baixar() async throws -> LinhaBackup? {
        guard let uid = UserDefaults.standard.string(forKey: "uidAtual") else { return nil }
        guard await temSessao() else { throw ErroBackup.semSessao }
        let linhas: [LinhaBackup] = try await Nuvem.client.from("backups")
            .select()
            .eq("user_id", value: uid.lowercased())
            .execute()
            .value
        return linhas.first
    }
}
