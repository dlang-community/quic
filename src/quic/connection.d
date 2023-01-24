module quic.connection;

import quic.frame_writer;
import quic.frame_reader;
import quic.packet;
import quic.frame;
import quic.crypto;

struct Session
{
    bool sessionOpened;
    bool connectCalled;
    bool handshakeDone;
    TLSContext tls;
    QuicWriter writer;
    ubyte[] destinationConnectionID;
    ubyte[] sourceConnectionID;
    
    void connect()
    {
        version (offlineTesting)
        {
            destinationConnectionID = cast(ubyte[]) hexString!"0001020304050607";
            sourceConnectionID = cast(ubyte[]) hexString!"05635f636964";
        }

        tls.clientPeerHello();
        bool connectCalled = true;
    }

    void sendDatagram(Writer)(ref Writer buffer)
    { 
        if (!sessionOpened && connectCalled) 
        {
            InitialPacket initialPacket;
            tls.writeMessage(initialPacket.payload);
            writer.getBytes(buffer, packet);
            sessionOpened = true;
        }
    }

    void receiveDatagram(ubyte[] data)
    {
        //initial type-packet
        if ((data[0] & 0x30) == 0)
        {
            ulong bufIndex;
            auto packetReader = QuicReader!InitialPacket(data, bufIndex);
            auto packetPayload = packetReader.read!"packetPayload";
            if (packetPayload[0] & 0x6) //crypto frame
            {
                ulong tlsBufIndex;
                auto reader = QuicReader!CryptoFrame(packetPayload, tlsBufIndex);
                //TODO: handle crypto frames split into multiple offsets
                auto frameOffset = reader.read!"offset";
                tls.handleMessage(reader.read!"cryptoData");
            }
        }
    }
}

struct TLSContext
{
    import std.conv : hexString;
    ubyte[] initialSalt = cast(ubyte[]) hexString!"38762cf7f55934b34d179ae6a4c80cadccbb7f0a";
    ubyte[] initialRandom;

    version (offlineTesting)
    {
        ubyte[] initialRandom = cast(ubyte[]) hexString!"000102030405060708";
    }

    ubyte[32] privateKey;
    ubyte[32] publicKey;
    ubyte[32] sharedKey;
    ubyte[16] derivedKey;
    ubyte[12] iv;
    ubyte[16] hp;

    ubyte[] pastMessages;

    int state;

    enum TlsStates { clientHandshakeStart, clientExpectServerHello,
                        clientExpectFinished, clientPostHandshake,
                        serverExpectClientHello, ServerExpectFinished,
                        serverPostHandshake }

    QuicWriter writer;

    void clientPeerHello()
    {
        generateKeyPair(privateKey, publicKey);

        version (offlineTesting)
        {
            import std.base64;
            publicKey == Base64.decode("NYBy1jZYgNGu6jKa35EhODhR7SGijjt16WXQ0s0WYlQ="); 
            privateKey == Base64.decode("ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=");
        }
        ubyte[] initialSecret, clientSecret; 
        hkdf_extract(initialSalt, initialRandom, initialSecret, 32);
        hkdf_expand_label(clientSecret, initialSecret, cast(ubyte[]) "client in", cast(ushort) 32);
        hkdf_expand_label(derivedKey, clientSecret, cast(ubyte[]) "quic key", cast(ushort) 16);
        hkdf_expand_label(iv, clientSecret, cast(ubyte[]) "quic key", cast(ushort) 12);
        hkdf_expand_label(hp, clientSecret, cast(ubyte[]) "quic hp", cast(ushort) 16);
    }

    void writeMessage(ref ubyte[] buffer)
    {
        if (state == TlsStates.clientHandshakeStart)
        {
            ClientHello helloFrame;
            KeyShare keyFrame;
            keyFrame.publicKey = publicKey;
            writer.getBytes(helloFrame.extensionData, keyFrame);
            writer.getBytes(buffer, helloFrame);
        }
    }
    
    void handleMessage(ubyte[] message)
    {
        if (state == TlsStates.clientExpectServerHello)
        {
            ulong tlsFrameIndex;
            auto reader = QuicReader!ServerHello(message, tlsFrameIndex);
            if (readBigEndianField(message, tlsFrameIndex, 2) == TlsFrameTypes.serverHello)
            {
                reader.read!"legacy_version";
                reader.read!"random";
                reader.read!"legacy_compression_method";
                handleServerHello(reader.read!"extensionData");
            }
            else
                assert(0, "Wrong message received");
        }
    }

    void handleServerHello(ubyte[] message)
    {
        ulong extensionIndex;
        if (readBigEndianField(message, extensionIndex, 2) ==
                                                TlsExtensionTypes.keyShare)
        {
            auto reader = QuicReader!KeyShare(message, extensionIndex);
            reader.groups;
            generateSharedKey(reader.publicKey[], privateKey[], sharedKey);
        }
    }
}
