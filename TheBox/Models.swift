import Foundation
import SwiftData

enum TipoTransacao: String, Codable, CaseIterable, Identifiable {
    case gasto, receita, transferencia
    var id: String { rawValue }
    var nome: String {
        switch self {
        case .gasto: return "Gasto"
        case .receita: return "Receita"
        case .transferencia: return "Transferência"
        }
    }
}

enum TipoCarteira: String, Codable, CaseIterable, Identifiable {
    case credito, debito, pix, dinheiro
    var id: String { rawValue }
    var nome: String {
        switch self {
        case .credito: return "Crédito"
        case .debito: return "Débito"
        case .pix: return "Pix"
        case .dinheiro: return "Dinheiro"
        }
    }
    var icone: String {
        switch self {
        case .credito, .debito: return "creditcard"
        case .pix: return "bolt.fill"
        case .dinheiro: return "banknote"
        }
    }
}

@Model
final class Categoria {
    var chave: UUID = UUID()
    var nome: String = ""
    var icone: String = "tag.fill"
    var tipoRaw: String = "gasto"
    /// Quanto pode gastar por mês nessa categoria (0 = sem limite)
    var limite: Double = 0
    /// Essencial (conta, mercado) ou desejo (lazer, compras)
    var essencial: Bool = true
    var ordem: Int = 0

    init(nome: String, icone: String, tipo: TipoTransacao, limite: Double = 0, essencial: Bool = true, ordem: Int = 0) {
        self.nome = nome
        self.icone = icone
        self.tipoRaw = tipo.rawValue
        self.limite = limite
        self.essencial = essencial
        self.ordem = ordem
    }

    var tipo: TipoTransacao { TipoTransacao(rawValue: tipoRaw) ?? .gasto }

    static func iconePadrao(_ nome: String) -> String {
        let n = nome.lowercased().folding(options: .diacriticInsensitive, locale: ptBR)
        let mapa: [(String, String)] = [
            ("aliment", "fork.knife"), ("mercado", "cart.fill"), ("restaurante", "fork.knife"),
            ("transporte", "car.fill"), ("uber", "car.fill"), ("combust", "fuelpump.fill"), ("carro", "car.fill"),
            ("saude", "heart.fill"), ("farmacia", "cross.case.fill"), ("academia", "dumbbell.fill"),
            ("assinatura", "rectangle.stack.fill"), ("lazer", "gamecontroller.fill"), ("viagem", "airplane"),
            ("moradia", "house.fill"), ("casa", "house.fill"), ("aluguel", "house.fill"),
            ("educacao", "book.fill"), ("curso", "book.fill"), ("pet", "pawprint.fill"),
            ("roupa", "tshirt.fill"), ("compra", "bag.fill"), ("presente", "gift.fill"),
            ("salario", "briefcase.fill"), ("freela", "laptopcomputer"), ("invest", "chart.line.uptrend.xyaxis"),
            ("reembolso", "arrow.uturn.backward"), ("venda", "tag.fill"), ("outro", "square.grid.2x2.fill")
        ]
        return mapa.first { n.contains($0.0) }?.1 ?? "tag.fill"
    }
}

@Model
final class Carteira {
    var chave: UUID = UUID()
    var nome: String = ""
    var tipoRaw: String = "credito"
    /// Dia de vencimento da fatura (só cartão de crédito)
    var diaVencimento: Int = 10
    var ordem: Int = 0
    /// Meses com fatura paga, no formato "2026-10"
    var faturasPagas: [String] = []
    /// Dia em que a fatura fecha (0 = não usar: compras no crédito saem do saldo na hora)
    var diaFechamento: Int = 0

    /// Com o dia de fechamento, as compras no crédito vão pra fatura e saem do saldo só no vencimento
    var usaFatura: Bool { tipo == .credito && diaFechamento > 0 }

    /// Mês (ver Mes.indice) em que vence a fatura de uma compra feita nessa data.
    /// Ex.: fecha dia 26 e vence dia 2 → compra em 10/out vence em 02/nov; compra em 27/out vence em 02/dez.
    func mesVencimento(da data: Date) -> Int {
        let dia = Calendar.current.component(.day, from: data)
        let fecha = Mes.indice(data) + (dia >= diaFechamento ? 1 : 0)
        return fecha + (diaVencimento <= diaFechamento ? 1 : 0)
    }

    init(nome: String, tipo: TipoCarteira, diaVencimento: Int = 10, ordem: Int = 0) {
        self.nome = nome
        self.tipoRaw = tipo.rawValue
        self.diaVencimento = diaVencimento
        self.ordem = ordem
    }

    var tipo: TipoCarteira { TipoCarteira(rawValue: tipoRaw) ?? .credito }
    func faturaPaga(em i: Int) -> Bool { faturasPagas.contains(Mes.chave(i)) }
    func alternarFatura(em i: Int) {
        let k = Mes.chave(i)
        if let x = faturasPagas.firstIndex(of: k) { faturasPagas.remove(at: x) } else { faturasPagas.append(k) }
    }
}

@Model
final class Transacao {
    var chave: UUID = UUID()
    var tipoRaw: String = "gasto"
    var valor: Double = 0
    var categoria: String = ""
    var carteira: String = ""
    var descricao: String = ""
    var data: Date = Date.now
    /// Só pra transferência: true = entrou na conta (resgate, veio de outra conta sua); false = saiu
    var entrada: Bool = false
    /// Foto do comprovante (opcional)
    @Attribute(.externalStorage) var foto: Data? = nil
    /// Transferência entre bancos seus: banco que recebeu (o que saiu está em `carteira`). Não muda o total.
    var destino: String = ""

    init(tipo: TipoTransacao, valor: Double, categoria: String, carteira: String, descricao: String,
         data: Date = .now, entrada: Bool = false) {
        self.tipoRaw = tipo.rawValue
        self.valor = valor
        self.categoria = categoria
        self.carteira = carteira
        self.descricao = descricao
        self.data = data
        self.entrada = entrada
    }

    var tipo: TipoTransacao { TipoTransacao(rawValue: tipoRaw) ?? .gasto }
    var mes: Int { Mes.indice(data) }
    var titulo: String { descricao.isEmpty ? categoria : descricao }

    static let categoriaAjuste = "Ajuste de saldo"
    /// Ajuste pra o saldo do app bater com o do banco (não conta como gasto nem receita de verdade)
    var ehAjuste: Bool { categoria == Transacao.categoriaAjuste }

    static let prefixoCaixinha = "Caixinha: "
    static let outraConta = "Outra conta minha"
    static let pagamentoFatura = "Pagamento de fatura"

    /// Nome da caixinha, se for uma transferência pra/de caixinha
    var nomeCaixinha: String? {
        guard tipo == .transferencia, categoria.hasPrefix(Transacao.prefixoCaixinha) else { return nil }
        return String(categoria.dropFirst(Transacao.prefixoCaixinha.count))
    }

    /// Efeito no saldo da conta: + entra, - sai
    var efeitoNoSaldo: Double {
        switch tipo {
        case .gasto: return -valor
        case .receita: return valor
        case .transferencia: return !destino.isEmpty ? 0 : (entrada ? valor : -valor)
        }
    }

    /// Cópia solta (ainda não salva), usada pra desfazer uma exclusão
    func copia() -> Transacao {
        let c = Transacao(tipo: tipo, valor: valor, categoria: categoria, carteira: carteira, descricao: descricao,
                          data: data, entrada: entrada)
        c.foto = foto
        c.destino = destino
        return c
    }
}

@Model
final class Conta {
    var chave: UUID = UUID()
    var nome: String = ""
    var valor: Double = 0
    var dia: Int = 10
    var venceMesSeguinte: Bool = false
    var categoria: String = ""
    /// Repete todo mês (sem parcelas definidas)
    var repetir: Bool = true
    /// Parcelas: 0 = não é parcelada
    var parcelaAtual: Int = 0
    var totalParcelas: Int = 0
    /// Mês (ver Mes.indice) em que aparece pela primeira vez / da parcela atual
    var inicio: Int = 0
    /// Pagamentos no formato "2026-10|Nubank"
    var pagamentos: [String] = []
    /// Meses apagados só daquele mês ("apagar só essa"), formato "2026-10"
    var excluidos: [String] = []
    /// Parcelas pagas adiantado (saem do fim do parcelamento)
    var adiantadas: Int = 0
    /// Juros ao mês em % (opcional, usado no método avalanche)
    var juros: Double = 0
    /// Último mês em que a conta aparece (0 = sem fim). Usado quando a lista de contas é substituída.
    var fim: Int = 0

    init(nome: String, valor: Double, dia: Int, venceMesSeguinte: Bool, categoria: String,
         repetir: Bool, parcelaAtual: Int, totalParcelas: Int, inicio: Int) {
        self.nome = nome
        self.valor = valor
        self.dia = dia
        self.venceMesSeguinte = venceMesSeguinte
        self.categoria = categoria
        self.repetir = repetir
        self.parcelaAtual = parcelaAtual
        self.totalParcelas = totalParcelas
        self.inicio = inicio
    }

    var parcelada: Bool { totalParcelas > 0 }
    var tipoNome: String { parcelada ? "Parcelado" : (repetir ? "Fixo" : "Única") }

    var recorrente: Bool { parcelada || repetir }

    func ocorre(em i: Int) -> Bool {
        if excluidos.contains(Mes.chave(i)) { return false }
        if fim > 0 && i > fim { return false }
        let d = i - inicio
        if d < 0 { return false }
        if parcelada { return max(parcelaAtual, 1) + d <= totalParcelas - adiantadas }
        return repetir || d == 0
    }

    func parcela(em i: Int) -> String? {
        guard parcelada else { return nil }
        return "\(max(parcelaAtual, 1) + i - inicio)/\(totalParcelas)"
    }

    /// Pagamento salvo como "2026-11|Pix" ou, quando pago adiantado, "2026-11|Pix|2026-10" (mês em que pagou)
    private func registroPagamento(em i: Int) -> [String]? {
        let prefixo = Mes.chave(i) + "|"
        guard let p = pagamentos.first(where: { $0.hasPrefix(prefixo) }) else { return nil }
        return p.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }

    func pagamento(em i: Int) -> String? {
        registroPagamento(em: i).map { $0.count > 1 ? $0[1] : "" }
    }

    /// "2026-10" → índice do mês (ver Mes.indice)
    static func mes(_ chave: String) -> Int? {
        let p = chave.split(separator: "-")
        guard p.count == 2, let a = Int(p[0]), let m = Int(p[1]) else { return nil }
        return a * 12 + m - 1
    }

    func pago(em i: Int) -> Bool { pagamento(em: i) != nil }

    func marcarPago(em i: Int, carteira: String) {
        desmarcar(em: i)
        // conta de um mês que ainda não chegou: guarda o mês em que o dinheiro saiu de verdade
        let hoje = Mes.indice()
        pagamentos.append(Mes.chave(i) + "|" + carteira + (i > hoje ? "|" + Mes.chave(hoje) : ""))
    }

    func desmarcar(em i: Int) {
        let prefixo = Mes.chave(i) + "|"
        pagamentos.removeAll { $0.hasPrefix(prefixo) }
    }

    /// Tira a conta só desse mês (os outros continuam)
    func excluir(em i: Int) {
        let k = Mes.chave(i)
        if !excluidos.contains(k) { excluidos.append(k) }
    }

    func restaurar(em i: Int) {
        excluidos.removeAll { $0 == Mes.chave(i) }
    }

    /// Cópia solta (ainda não salva), usada pra desfazer uma exclusão
    func copia() -> Conta {
        let c = Conta(nome: nome, valor: valor, dia: dia, venceMesSeguinte: venceMesSeguinte, categoria: categoria,
                      repetir: repetir, parcelaAtual: parcelaAtual, totalParcelas: totalParcelas, inicio: inicio)
        c.pagamentos = pagamentos
        c.excluidos = excluidos
        c.adiantadas = adiantadas
        c.juros = juros
        c.fim = fim
        return c
    }

    func vencimento(em i: Int, hora: Int = 9) -> Date {
        Mes.data(venceMesSeguinte ? i + 1 : i, dia: dia, hora: hora)
    }

    func atrasada(em i: Int) -> Bool {
        if pago(em: i) { return false }
        return vencimento(em: i, hora: 23) < .now
    }
}

/// Limite de gastos do mês. Vale a partir de `mes` até ser trocado.
@Model
final class LimiteMensal {
    var mes: Int = 0
    var valor: Double = 0
    init(mes: Int, valor: Double) {
        self.mes = mes
        self.valor = valor
    }
}

// MARK: - Contas do mês

struct Financas {
    var transacoes: [Transacao] = []
    var contas: [Conta] = []
    var carteiras: [Carteira] = []
    var limites: [LimiteMensal] = []
    var recorrencias: [Recorrencia] = []

    func credito(_ nome: String) -> Bool {
        carteiras.first { $0.nome == nome }?.tipo == .credito
    }

    func transacoes(em m: Int) -> [Transacao] { transacoes.filter { $0.mes == m } }

    func receitas(em m: Int) -> Double {
        transacoes(em: m).filter { $0.tipo == .receita }.reduce(0) { $0 + $1.valor }
    }

    /// Cartão com fatura automática (tem dia de fechamento) usado nessa transação
    func cartaoComFatura(_ t: Transacao) -> Carteira? {
        guard t.tipo == .gasto else { return nil }
        return carteiras.first { $0.nome == t.carteira && $0.usaFatura }
    }

    /// Todos os gastos registrados no mês da compra (pra ver quanto você gasta)
    func gastosTransacoes(em m: Int) -> Double {
        transacoes(em: m).filter { $0.tipo == .gasto && !$0.ehAjuste }.reduce(0) { $0 + $1.valor }
    }

    /// Gastos que saem do saldo na hora (os do cartão com fatura só saem no vencimento)
    func gastosAvulsos(em m: Int) -> Double {
        transacoes(em: m).filter { $0.tipo == .gasto && cartaoComFatura($0) == nil }.reduce(0) { $0 + $1.valor }
    }

    /// Compras no crédito que caem na fatura desse cartão com vencimento no mês m
    func comprasNaFatura(_ c: Carteira, em m: Int) -> [Transacao] {
        guard c.usaFatura else { return [] }
        return transacoes.filter { $0.tipo == .gasto && $0.carteira == c.nome && c.mesVencimento(da: $0.data) == m }
    }

    func contasDoMes(_ m: Int) -> [Conta] {
        contas.filter { $0.ocorre(em: m) }.sorted { $0.dia < $1.dia }
    }

    func contasPagas(em m: Int) -> [Conta] {
        contas.filter { $0.ocorre(em: m) && $0.pago(em: m) }
    }

    /// Contas pagas fora do cartão de crédito que saíram do saldo no mês m
    /// (inclusive as de meses seguintes pagas adiantado neste mês)
    func contasPagasFora(em m: Int) -> Double {
        contas.reduce(0) { soma, c in
            soma + c.pagamentos.reduce(0) { s, p in
                let e = p.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard let mesConta = Conta.mes(e[0]) else { return s }
                let mesPago = e.count > 2 ? (Conta.mes(e[2]) ?? mesConta) : mesConta
                let carteira = e.count > 1 ? e[1] : ""
                return mesPago == m && c.ocorre(em: mesConta) && !credito(carteira) ? s + c.valor : s
            }
        }
    }

    /// Fatura do cartão que vence no mês m: compras no crédito do período (se o cartão tem dia de
    /// fechamento) + contas marcadas como pagas com ele no mês anterior
    func fatura(_ c: Carteira, em m: Int) -> Double {
        let contasNoCartao = contas.filter { $0.ocorre(em: m - 1) && $0.pagamento(em: m - 1) == c.nome }
            .reduce(0) { $0 + $1.valor }
        let compras = comprasNaFatura(c, em: m).reduce(0) { $0 + $1.valor }
        return contasNoCartao + compras
    }

    func cartoes() -> [Carteira] { carteiras.filter { $0.tipo == .credito } }

    func faturasPagas(em m: Int) -> Double {
        cartoes().filter { $0.faturaPaga(em: m) }.reduce(0) { $0 + fatura($1, em: m) }
    }

    /// Transferências do mês (caixinha, outra conta sua, pagamento de fatura): + entrou, - saiu
    func transferenciasLiquidas(em m: Int) -> Double {
        transacoes(em: m).filter { $0.tipo == .transferencia }.reduce(0) { $0 + $1.efeitoNoSaldo }
    }

    /// Receitas fixas (ex.: salário) que ainda vão entrar nesse mês
    func receitasAReceber(em m: Int) -> Double {
        recorrencias.filter { $0.ativa && m > $0.ultimoMes }.reduce(0) { $0 + $1.valor }
    }

    /// O que entrou e saiu da conta só dentro do mês m
    func movimento(em m: Int) -> Double {
        receitas(em: m) - gastosAvulsos(em: m) - contasPagasFora(em: m) - faturasPagas(em: m)
            + transferenciasLiquidas(em: m)
    }

    /// Dinheiro que veio do mês anterior (igual ao banco: o que sobra continua na conta).
    /// Meses passados: o que de fato aconteceu. Meses futuros: a sobra prevista do mês anterior.
    func abertura(em m: Int) -> Double {
        let hoje = Mes.indice()
        if m > hoje { return saldoPrevisto(em: m - 1) }
        guard let primeiro = transacoes.map(\.mes).min(), primeiro < m else { return 0 }
        return (primeiro..<m).reduce(0) { $0 + movimento(em: $1) }
    }

    /// Saldo de hoje: o que veio do mês anterior + o que já entrou e já foi pago no mês
    func saldo(em m: Int) -> Double {
        abertura(em: m) + movimento(em: m)
    }

    /// Soma dos ajustes de saldo do mês (+ entrou, - saiu). Com `carteira`, só os ajustes daquela conta.
    func ajustes(em m: Int, carteira: String? = nil) -> Double {
        transacoes(em: m).filter { $0.ehAjuste && (carteira == nil || $0.carteira == carteira) }
            .reduce(0) { $0 + ($1.tipo == .receita ? $1.valor : -$1.valor) }
    }

    /// Quanto tem num banco até o fim do mês m: o que entrou e saiu registrado nele,
    /// as transferências entre seus bancos e as contas pagas com ele
    func saldoCarteira(_ nome: String, ate m: Int) -> Double {
        var s = 0.0
        for t in transacoes where t.mes <= m {
            if t.carteira == nome {
                switch t.tipo {
                case .receita: s += t.valor
                case .gasto: if cartaoComFatura(t) == nil { s -= t.valor }
                case .transferencia: s += t.destino.isEmpty ? t.efeitoNoSaldo : -t.valor
                }
            }
            if t.tipo == .transferencia && t.destino == nome { s += t.valor }
        }
        for c in contas {
            for p in c.pagamentos {
                let e = p.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard e.count > 1, e[1] == nome, let mesConta = Conta.mes(e[0]) else { continue }
                let mesPago = e.count > 2 ? (Conta.mes(e[2]) ?? mesConta) : mesConta
                if mesPago <= m && c.ocorre(em: mesConta) { s -= c.valor }
            }
        }
        return s
    }

    /// Bancos e dinheiro (tudo que não é cartão de crédito)
    func bancos() -> [Carteira] { carteiras.filter { $0.tipo != .credito } }

    /// "Pode gastar hoje": o que sobra até o fim do mês dividido pelos dias que faltam
    func podeGastarHoje() -> (resta: Double, porDia: Double, temBase: Bool) {
        let mes = Mes.indice()
        let cal = Calendar.current
        let diasNoMes = cal.range(of: .day, in: .month, for: .now)?.count ?? 30
        let dias = max(1, diasNoMes - cal.component(.day, from: .now) + 1)
        let gastoHoje = transacoes(em: mes).filter { $0.tipo == .gasto && !$0.ehAjuste && cal.isDateInToday($0.data) }
            .reduce(0) { $0 + $1.valor }
        let lim = limite(em: mes)
        let porLimite = lim - gastoTotal(em: mes) - contasAPagar(em: mes)
        let previsto = saldoPrevisto(em: mes)
        let disponivel = (lim > 0 ? min(porLimite, previsto) : previsto) + gastoHoje
        let porDia = max(0, disponivel) / Double(dias)
        let temBase = receitas(em: mes) + receitasAReceber(em: mes) > 0 || abertura(em: mes) > 0
        return (porDia - gastoHoje, porDia, temBase)
    }

    /// Contas do mês que ainda não foram marcadas como pagas
    func contasAPagar(em m: Int) -> Double {
        contasDoMes(m).filter { !$0.pago(em: m) }.reduce(0) { $0 + $1.valor }
    }

    func faturasAPagar(em m: Int) -> Double {
        cartoes().filter { !$0.faturaPaga(em: m) }.reduce(0) { $0 + fatura($1, em: m) }
    }

    /// Quanto sobra no fim do mês depois de pagar todas as contas e faturas
    func saldoPrevisto(em m: Int) -> Double {
        saldo(em: m) + receitasAReceber(em: m) - contasAPagar(em: m) - faturasAPagar(em: m)
    }

    /// Quanto tem guardado numa caixinha (o que já tinha + guardados - resgates)
    func saldoCaixinha(_ c: Caixinha) -> Double {
        let chave = Transacao.prefixoCaixinha + c.nome
        return c.saldoInicial + transacoes.filter { $0.tipo == .transferencia && $0.categoria == chave }
            .reduce(0) { $0 + ($1.entrada ? -$1.valor : $1.valor) }
    }

    /// Gastos do mês por categoria (transações + contas pagas)
    func gastoPorCategoria(em m: Int) -> [String: Double] {
        var r: [String: Double] = [:]
        for t in transacoes(em: m) where t.tipo == .gasto && !t.ehAjuste { r[t.categoria, default: 0] += t.valor }
        for c in contasPagas(em: m) { r[c.categoria.isEmpty ? "Outros" : c.categoria, default: 0] += c.valor }
        return r
    }

    func gastoTotal(em m: Int) -> Double { gastoPorCategoria(em: m).values.reduce(0, +) }

    func limite(em m: Int) -> Double {
        if let l = limites.filter({ $0.mes <= m }).max(by: { $0.mes < $1.mes }) { return l.valor }
        return limites.min(by: { $0.mes < $1.mes })?.valor ?? 0
    }

    func temDados(em m: Int) -> Bool {
        !transacoes(em: m).isEmpty || !contasPagas(em: m).isEmpty
    }
}

/// Receita que se repete todo mês (ex.: salário): entra sozinha no dia
@Model
final class Recorrencia {
    var chave: UUID = UUID()
    var nome: String = ""
    var valor: Double = 0
    var dia: Int = 5
    var categoria: String = ""
    var carteira: String = ""
    /// Último mês (ver Mes.indice) em que a receita já foi lançada
    var ultimoMes: Int = 0
    var ativa: Bool = true

    init(nome: String, valor: Double, dia: Int, categoria: String, carteira: String, ultimoMes: Int) {
        self.nome = nome
        self.valor = valor
        self.dia = dia
        self.categoria = categoria
        self.carteira = carteira
        self.ultimoMes = ultimoMes
    }
}

/// Dinheiro guardado com um objetivo (reserva, quitar dívida, viagem)
@Model
final class Caixinha {
    var chave: UUID = UUID()
    var nome: String = ""
    var meta: Double = 0
    /// O que já estava guardado quando a caixinha foi criada
    var saldoInicial: Double = 0
    var prazo: Date? = nil
    var ordem: Int = 0

    init(nome: String, meta: Double, saldoInicial: Double, prazo: Date?, ordem: Int) {
        self.nome = nome
        self.meta = meta
        self.saldoInicial = saldoInicial
        self.prazo = prazo
        self.ordem = ordem
    }
}
