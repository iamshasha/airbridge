using System.Collections.Concurrent;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using System.Text.Json.Serialization;
using AirBridge.Engine;
using AirBridge.Net;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Radios;

namespace AirBridge.App;

/// <summary>
/// Bluetooth LE presence, compatible with the Mac/iPhone apps: scans for the AirBridge service and reads each
/// device's contact card (id, name, port, addresses), and hosts our own card for them to read.
/// Lets devices find each other where Wi-Fi multicast is blocked (guest and office networks).
/// </summary>
public sealed class BluetoothService : IDisposable
{
    static readonly Guid ServiceUuid = Guid.Parse("5A1B0001-6A3F-4E8E-9D2C-A1B2C3D4E5F6");
    static readonly Guid CardUuid = Guid.Parse("5A1B0002-6A3F-4E8E-9D2C-A1B2C3D4E5F6");

    sealed record Card(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("n")] string N,
        [property: JsonPropertyName("fp")] string Fp,
        [property: JsonPropertyName("pl")] string Pl,
        [property: JsonPropertyName("p")] int P,
        [property: JsonPropertyName("a")] List<string> A);

    readonly Node _node;
    readonly BluetoothLEAdvertisementWatcher _watcher = new() { ScanningMode = BluetoothLEScanningMode.Active };
    readonly ConcurrentDictionary<ulong, DateTimeOffset> _lastRead = new();
    GattServiceProvider? _provider;

    BluetoothService(Node node) => _node = node;

    public static async Task<(string State, bool LowEnergy)> ProbeAsync()
    {
        try
        {
            var adapter = await BluetoothAdapter.GetDefaultAsync();
            if (adapter is null) return ("no adapter", false);
            var radio = await adapter.GetRadioAsync();
            var state = radio?.State switch
            {
                RadioState.On => "on",
                RadioState.Off => "off",
                RadioState.Disabled => "disabled",
                _ => "unknown",
            };
            return (state, adapter.IsLowEnergySupported && radio?.State == RadioState.On);
        }
        catch (Exception) { return ("unavailable", false); }
    }

    public static async Task<BluetoothService?> StartAsync(Node node)
    {
        var (_, le) = await ProbeAsync();
        if (!le) return null;
        var service = new BluetoothService(node);
        service.StartScanning();
        await service.StartHostingAsync();
        return service;
    }

    void StartScanning()
    {
        _watcher.AdvertisementFilter.Advertisement.ServiceUuids.Add(ServiceUuid);
        _watcher.Received += (watcher, args) =>
        {
            // Read a device's card at most once a minute.
            var now = DateTimeOffset.Now;
            if (_lastRead.TryGetValue(args.BluetoothAddress, out var last) && now - last < TimeSpan.FromMinutes(1)) return;
            _lastRead[args.BluetoothAddress] = now;
            _ = ReadCardAsync(args.BluetoothAddress, args.RawSignalStrengthInDBm);
        };
        _watcher.Start();
    }

    async Task ReadCardAsync(ulong address, short rssi)
    {
        try
        {
            using var device = await BluetoothLEDevice.FromBluetoothAddressAsync(address);
            if (device is null) return;
            var services = await device.GetGattServicesForUuidAsync(ServiceUuid, BluetoothCacheMode.Uncached);
            if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0) return;
            using var service = services.Services[0];
            var chars = await service.GetCharacteristicsForUuidAsync(CardUuid, BluetoothCacheMode.Uncached);
            if (chars.Status != GattCommunicationStatus.Success || chars.Characteristics.Count == 0) return;
            var value = await chars.Characteristics[0].ReadValueAsync(BluetoothCacheMode.Uncached);
            if (value.Status != GattCommunicationStatus.Success) return;
            var card = JsonSerializer.Deserialize<Card>(value.Value.ToArray());
            if (card is null) return;
            _node.UpdatePeer(card.Id, card.N, card.Pl, card.Fp, DiscoverySource.Bluetooth,
                card.A.Select(a => new Endpoint(a, card.P)).ToList(), rssi);
        }
        catch (Exception) { _lastRead.TryRemove(address, out _); }
    }

    async Task StartHostingAsync()
    {
        var created = await GattServiceProvider.CreateAsync(ServiceUuid);
        if (created.Error != BluetoothError.Success) return;
        _provider = created.ServiceProvider;
        var characteristic = await _provider.Service.CreateCharacteristicAsync(CardUuid, new GattLocalCharacteristicParameters
        {
            CharacteristicProperties = GattCharacteristicProperties.Read,
            ReadProtectionLevel = GattProtectionLevel.Plain,
        });
        if (characteristic.Error != BluetoothError.Success) return;
        characteristic.Characteristic.ReadRequested += async (_, args) =>
        {
            using var deferral = args.GetDeferral();
            var request = await args.GetRequestAsync();
            if (request is null) return;
            var card = new Card(_node.Identity.Id, _node.Settings.DeviceName, _node.Identity.Fingerprint, "win",
                _node.ListeningPort ?? 0, Mdns.LocalAddresses().Take(4).Select(a => a.ToString()).ToList());
            var bytes = JsonSerializer.SerializeToUtf8Bytes(card);
            var offset = (int)Math.Min(request.Offset, (uint)bytes.Length);
            request.RespondWithValue(bytes.AsBuffer(offset, bytes.Length - offset));
        };
        _provider.StartAdvertising(new GattServiceProviderAdvertisingParameters { IsConnectable = true, IsDiscoverable = true });
    }

    public void Dispose()
    {
        _watcher.Stop();
        _provider?.StopAdvertising();
    }
}
