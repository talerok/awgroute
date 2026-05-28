import Foundation
import AwgConfig

/// Связывает `ProfileStore` и `BackendController`:
/// материализует активный профиль в JSON-конфиг для amnezia-box и
/// дёргает backend.start/stop. Вынесено отдельно, чтобы UI остался плоским.
@MainActor
struct ConnectionCoordinator {
    let profiles: ProfileStore
    let backend: BackendController
    let rules: RulesStore?

    func connect() async {
        guard let profile = profiles.activeProfile else {
            // Здесь специально не показываем алерт — это инвариант UI: кнопка disabled.
            return
        }
        do {
            let materialized = try profiles.materializedConfig(for: profile)
            var opts = AwgJSONGenerator.Options()
            opts.endpointTag = "vpn"        // зарезервированное имя; rules.json пользователя видит "vpn"

            // Умный дефолт DNS: пропускаем CGNAT-адреса (100.64.0.0/10) — это
            // внутренние DNS VPN-сервера, они часто тормозят на части доменов.
            // Берём первый публичный из .conf, fallback на 1.1.1.1.
            opts.remoteDNSServer = materialized.interface.dns
                .first { Self.isPublicIPv4DNS($0) } ?? "1.1.1.1"

            // Smart-режим: наш sing-box TUN inbound + AWG endpoint, с пользовательскими
            // route-правилами. Native TUN режим (`useIntegratedTun=true`) оставлен в
            // генераторе для возможной отладки, но в UI переключатель убран — он плохо
            // снимает auto_route на macOS, после disconnect ломается системная сеть.
            //
            // Пользовательские правила (Variant A) могут содержать опциональную секцию
            // `dns` (Variant B) — она перекроет дефолтную DNS-конфигурацию генератора.
            let parsedRules = try? rules?.parsed()
            let userRoute: [String: Any]? = parsedRules
            let userDNS: [String: Any]? = parsedRules?["dns"] as? [String: Any]
            let json = try AwgJSONGenerator.fullConfigJSON(
                from: materialized,
                options: opts,
                userRoute: userRoute,
                userDNS: userDNS
            )
            // Mode 600: конфиг содержит распакованный AWG private key. Только текущий user.
            try json.write(to: Paths.activeConfig, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Paths.activeConfig.path
            )

            // System DNS override (через helper, scutil-based). Цель:
            // 1. macOS-приложения резолвят через VPN-DNS, а не через ISP-роутер,
            //    который часто отдаёт «отравленные» ответы для известных доменов
            //    (например, 8.6.112.0 вместо реального Cloudflare IP — Chrome зависает,
            //    Firefox с DoH работает).
            // 2. Apple iCloud Private Relay выключается при non-default DNS — иначе
            //    он подменяет destinations на свои Apple-edge endpoints, которые
            //    через VPN не подключаются.
            //
            // Порядок: первым — DNS из профиля (внутренний VPN-резолвер если есть,
            // либо публичный); дальше публичные fallback'и (1.1.1.1, 8.8.8.8),
            // чтобы при задержке backend-start или временной потере VPN резолвинг
            // не вставал колом — публичные доступны напрямую.
            let systemDNS = Self.buildSystemDNSList(profileDNS: materialized.interface.dns)
            await backend.start(configPath: Paths.activeConfig.path, dnsServers: systemDNS)
        } catch {
            // Без этого пользователь жмёт Connect и думает что приложение зависло.
            backend.reportError("connect failed: \(error.localizedDescription)")
        }
    }

    /// Возвращает true если адрес — валидный публичный IPv4 DNS.
    /// Отфильтровывает IPv6 (содержат ':'), CGNAT 100.64.0.0/10 (VPN-internal DNS).
    private static func isPublicIPv4DNS(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return !(parts[0] == 100 && (64...127).contains(parts[1]))
    }

    /// Собирает DNS-список для system override через helper. Логика:
    /// - первым идут серверы из профиля (порядок как в .conf) — внутренний VPN-DNS
    ///   и/или указанные провайдером публичные;
    /// - в конец — публичные fallback'и (1.1.1.1, 8.8.8.8), если они там ещё не были.
    ///   Они нужны на случай задержки старта backend'а или временной потери VPN:
    ///   внутренний DNS без работающего туннеля не отвечает, и system без резолвинга.
    /// IPv6-адреса оставляем как есть — scutil умеет их применять, macOS ходит к ним.
    static func buildSystemDNSList(profileDNS: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for dns in profileDNS {
            let trimmed = dns.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        for fallback in ["1.1.1.1", "8.8.8.8"] where seen.insert(fallback).inserted {
            result.append(fallback)
        }
        return result
    }

    func disconnect() async {
        await backend.stop()
        // Удалить рантайм-конфиг с распакованным private key.
        // Файл существует только пока backend работает (amnezia-box читает его при старте,
        // не следит за изменениями). Оставлять после disconnect нет причин.
        try? FileManager.default.removeItem(at: Paths.activeConfig)
    }

    /// Полная переактивация: stop → connect (для случая, когда пользователь
    /// меняет активный профиль во время работы туннеля).
    func switchTo(profile: Profile) async {
        let wasRunning: Bool = {
            if case .running = backend.status { return true }
            return false
        }()
        if wasRunning { await backend.stop() }
        profiles.activeID = profile.id
        if wasRunning { await connect() }
    }
}
