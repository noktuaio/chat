require 'rails_helper'
require 'stringio'

RSpec.describe ActiveStorage::Migrator do
  describe '.migrate' do
    let(:from_service_stub) { instance_double(ActiveStorage::Service) }
    let(:to_service_stub) { instance_double(ActiveStorage::Service) }

    before do
      allow(ActiveStorage::Service).to receive(:configure).with('local', any_args).and_return(from_service_stub)
      allow(ActiveStorage::Service).to receive(:configure).with('amazon', any_args).and_return(to_service_stub)
    end

    context 'when services are configured correctly' do
      it 'migrates blobs from one service to another' do
        expect(ActiveStorage::Service).to receive(:configure).with('local', any_args)
        expect(ActiveStorage::Service).to receive(:configure).with('amazon', any_args)
        expect(described_class).to receive(:migrate_blobs).with(from_service_stub, to_service_stub, 'amazon', update_service_name: true)
        expect { described_class.migrate('local', 'amazon') }.not_to raise_error
      end

      it 'passes the service-name update flag to blob migration' do
        expect(described_class).to receive(:migrate_blobs).with(from_service_stub, to_service_stub, 'amazon', update_service_name: false)

        described_class.migrate('local', 'amazon', update_service_name: false)
      end
    end

    context 'when services are not configured correctly' do
      it 'prints an error message' do
        allow(ActiveStorage::Service).to receive(:configure).and_return(nil)
        expect do
          described_class.migrate('random', 'random')
        end.to raise_error(RuntimeError, "Error: The services 'random' or 'random' are not configured correctly.")
      end
    end
  end

  describe '.migrate_blobs' do
    let(:from_service_stub) { instance_double(ActiveStorage::Service) }
    let(:to_service_stub) { instance_double(ActiveStorage::Service) }
    let(:blob) { instance_double(ActiveStorage::Blob, image?: true, key: 'blob-key', checksum: 'checksum') }
    let(:io) { StringIO.new('blob-content') }

    before do
      allow(ActiveStorage::Blob).to receive(:find_each).and_yield(blob)
      allow(blob).to receive(:open).and_yield(io)
    end

    it 'updates the blob service after uploading to the target service' do
      expect(to_service_stub).to receive(:upload).with('blob-key', io, checksum: 'checksum').ordered
      expect(blob).to receive(:update!).with(service_name: 'amazon').ordered

      described_class.migrate_blobs(from_service_stub, to_service_stub, :amazon, update_service_name: true)
    end

    it 'skips the blob service update when the flag is disabled' do
      expect(to_service_stub).to receive(:upload).with('blob-key', io, checksum: 'checksum')
      expect(blob).not_to receive(:update!)

      described_class.migrate_blobs(from_service_stub, to_service_stub, :amazon, update_service_name: false)
    end

    it 'does not update the blob service when upload fails' do
      allow(to_service_stub).to receive(:upload).and_raise(ActiveStorage::IntegrityError)

      expect(blob).not_to receive(:update!)
      expect do
        described_class.migrate_blobs(from_service_stub, to_service_stub, :amazon, update_service_name: true)
      end.to raise_error(ActiveStorage::IntegrityError)
    end
  end
end
