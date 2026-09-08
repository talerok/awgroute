import Foundation
import AwgInfrastructure
import AwgPresentation
import AwgDomain
import AwgConfig

/// Корень композиции — единственное место, где конкретные реализации встречаются
/// с портами домена.
///
/// Всё остальное приложение видит только протоколы: `Presentation` не знает про
/// Keychain, файлы и сокеты, `AwgDomain` не знает вообще ни о чём внешнем. Заменить
/// helper, backend или хранилище можно правкой одного этого файла.
@MainActor
final class AppContainer {

    let profiles: ProfileStore
    let rules: RulesStore
    let tunnel: TunnelStore
    let logs: LogViewModel
    let telemetry: Telemetry
    let supervisor: TunnelSupervisor
    let engine: EngineStore
    let installer: EngineInstalling

    private let paths = AppPaths.shared

    init() {
        // ── Адаптеры ──
        let secrets = KeychainSecretStore()
        let renderer = SingBoxConfigRenderer()
        let gateway = EngineTunnelGateway()
        let rulesRepo = FileRulesRepository(file: paths.rulesFile)
        let profileRepo = FileProfileRepository(directory: paths.profilesDir)
        let logSource = FileLogSource(fileURL: paths.backendLogURL)
        let network = SystemNetworkMonitor()
        let clashSecrets = ClashSecretProvider()
        let installer = SystemEngineInstaller()

        // ── Сценарии ──
        let build = BuildTunnelConfig(
            renderer: renderer,
            validator: BackendConfigValidator(),
            materialize: MaterializeProfile(secrets: secrets),
            // Сценарий читает СОХРАНЁННЫЕ правила, а не текст из редактора:
            // домену незачем знать про несохранённые правки.
            rules: rulesRepo,
            paths: paths,
            secretGenerator: clashSecrets
        )
        let connect = ConnectTunnel(build: build, gateway: gateway)
        let disconnect = DisconnectTunnel(gateway: gateway)

        // ── Наблюдаемое состояние ──
        self.installer = installer
        self.engine = EngineStore(control: EngineControl(), installer: installer)
        self.telemetry = Telemetry(source: ClashAPI(secrets: clashSecrets))
        self.rules = RulesStore(repository: rulesRepo, renderer: renderer)
        self.profiles = ProfileStore(
            repository: profileRepo,
            importProfile: ImportProfile(parser: AwgConfigParserAdapter(),
                                         repository: profileRepo, secrets: secrets),
            deleteProfile: DeleteProfile(repository: profileRepo, secrets: secrets)
        )
        let tunnel = TunnelStore(
            gateway: gateway,
            connect: connect,
            disconnect: disconnect,
            availability: BundledBackendAvailability()
        )
        self.tunnel = tunnel

        // Панель логов сама решает, когда следить за файлом: пока туннель поднят,
        // плюс пауза на предсмертный залп backend'а. Правило целиком внутри неё,
        // здесь только связывание.
        self.logs = LogViewModel(
            source: logSource,
            fileURL: paths.backendLogURL,
            statusUpdates: { [weak tunnel] in tunnel?.statusUpdates() ?? AsyncStream { $0.finish() } }
        )

        self.supervisor = TunnelSupervisor(
            tunnel: tunnel,
            profiles: profiles,
            reconnect: ReconnectTunnel(
                connect: connect,
                network: network,
                status: { [weak tunnel] in await tunnel?.status ?? .stopped }
            ),
            network: network,
            power: SystemPowerMonitor(),
            engine: installer
        )
    }
}
