require 'spec_helper'
require 'time'
require 'mock_redis'

# Custom RSpec :Matchers

# Match a Hashtable['name'] is an expected value
RSpec::Matchers.define :a_pool_with_name_of do |value|
  match { |actual| actual['name'] == value }
end

describe 'Pool Manager' do
  let(:logger) { MockLogger.new }
  let(:redis) { MockRedis.new }
  let(:metrics) { Vmpooler::DummyStatsd.new }
  let(:pool) { 'pool1' }
  let(:vm) { 'vm1' }
  let(:timeout) { 5 }
  let(:host) { double('host') }
  let(:token) { 'token1234'}

  let(:provider_options) { {} }
  let(:provider) { Vmpooler::PoolManager::Provider::Base.new(config, logger, metrics, 'mock_provider', provider_options) }

  let(:config) { YAML.load(<<-EOT
---
:config:
:providers:
  :mock:
:pools:
  - name: '#{pool}'
    size: 1
EOT
    )
  }

  subject { Vmpooler::PoolManager.new(config, logger, redis, metrics) }

  describe '#config' do
    before do
      expect(subject).not_to be_nil
    end

    it 'should return the current configuration' do
      expect(subject.config).to eq(config)
    end
  end

  describe '#check_pending_vm' do
    before do
      expect(subject).not_to be_nil
    end

    it 'calls _check_pending_vm' do
      expect(Thread).to receive(:new).and_yield
      expect(subject).to receive(:_check_pending_vm).with(vm,pool,timeout,provider)

      subject.check_pending_vm(vm, pool, timeout, provider)
    end
  end

  describe '#_check_pending_vm' do
    before do
      expect(subject).not_to be_nil
    end

    context 'host does not exist or not in pool' do
      it 'calls fail_pending_vm' do
        expect(provider).to receive(:get_vm).with(pool,vm).and_return(nil)
        expect(subject).to receive(:fail_pending_vm).with(vm, pool, timeout, false) 

        subject._check_pending_vm(vm, pool, timeout, provider)
      end
    end

    context 'host is in pool' do
      before do
        expect(provider).to receive(:get_vm).with(pool,vm).and_return(host)
      end

      it 'calls move_pending_vm_to_ready if host is ready' do
        expect(provider).to receive(:vm_ready?).with(pool,vm).and_return(true)
        expect(subject).to receive(:move_pending_vm_to_ready).with(vm, pool, host)

        subject._check_pending_vm(vm, pool, timeout, provider)
      end

      it 'calls fail_pending_vm if host is not ready' do
        expect(provider).to receive(:vm_ready?).with(pool,vm).and_return(false)
        expect(subject).to receive(:fail_pending_vm).with(vm, pool, timeout)

        subject._check_pending_vm(vm, pool, timeout, provider)
      end
    end
  end

  describe '#remove_nonexistent_vm' do
    before do
      expect(subject).not_to be_nil
    end

    it 'removes VM from pending in redis' do
      create_pending_vm(pool,vm)

      expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(true)
      subject.remove_nonexistent_vm(vm, pool)
      expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(false)
    end

    it 'logs msg' do
      expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' no longer exists. Removing from pending.")

      subject.remove_nonexistent_vm(vm, pool)
    end
  end

 describe '#fail_pending_vm' do
    before do
      expect(subject).not_to be_nil
    end

    before(:each) do
      create_pending_vm(pool,vm)
    end

    it 'takes no action if VM is not cloning' do
      expect(subject.fail_pending_vm(vm, pool, timeout)).to eq(true)
      expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(true)
    end

    it 'takes no action if VM is within timeout' do
      redis.hset("vmpooler__vm__#{vm}", 'clone',Time.now.to_s)
      expect(subject.fail_pending_vm(vm, pool, timeout)).to eq(true)
      expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(true)
    end

    it 'moves VM to completed queue if VM has exceeded timeout and exists' do
      redis.hset("vmpooler__vm__#{vm}", 'clone',Date.new(2001,1,1).to_s)
      expect(subject.fail_pending_vm(vm, pool, timeout,true)).to eq(true)
      expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(false)
      expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(true)
    end

    it 'logs message if VM has exceeded timeout and exists' do
      redis.hset("vmpooler__vm__#{vm}", 'clone',Date.new(2001,1,1).to_s)
      expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' marked as 'failed' after #{timeout} minutes")
      expect(subject.fail_pending_vm(vm, pool, timeout,true)).to eq(true)
    end

    it 'calls remove_nonexistent_vm if VM has exceeded timeout and does not exist' do
      redis.hset("vmpooler__vm__#{vm}", 'clone',Date.new(2001,1,1).to_s)
      expect(subject).to receive(:remove_nonexistent_vm).with(vm, pool)
      expect(subject.fail_pending_vm(vm, pool, timeout,false)).to eq(true)
    end

    it 'swallows error if an error is raised' do
      redis.hset("vmpooler__vm__#{vm}", 'clone','iamnotparsable_asdate')
      expect(subject.fail_pending_vm(vm, pool, timeout,true)).to eq(false)
    end

    it 'logs message if an error is raised' do
      redis.hset("vmpooler__vm__#{vm}", 'clone','iamnotparsable_asdate')
      expect(logger).to receive(:log).with('d', String)

      subject.fail_pending_vm(vm, pool, timeout,true)
    end
  end
  
  describe '#move_pending_vm_to_ready' do
    let(:host) { { 'hostname' => vm }}

    before do
      expect(subject).not_to be_nil
      allow(Socket).to receive(:getaddrinfo)
    end

    before(:each) do
      create_pending_vm(pool,vm)
    end

    context 'when hostname does not match VM name' do
      it 'should not take any action' do
        expect(logger).to receive(:log).exactly(0).times
        expect(Socket).to receive(:getaddrinfo).exactly(0).times

        host['hostname'] = 'different_name'

        subject.move_pending_vm_to_ready(vm, pool, host)
      end
    end

    context 'when hostname matches VM name' do
      it 'should move the VM from pending to ready pool' do
        expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(true)
        expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(false)
        subject.move_pending_vm_to_ready(vm, pool, host)
        expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(false)
        expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(true)
      end

      it 'should log a message' do
        expect(logger).to receive(:log).with('s', "[>] [#{pool}] '#{vm}' moved from 'pending' to 'ready' queue")

        subject.move_pending_vm_to_ready(vm, pool, host)
      end

      it 'should set the boot time in redis' do
        redis.hset("vmpooler__vm__#{vm}", 'clone',Time.now.to_s)
        expect(redis.hget('vmpooler__boot__' + Date.today.to_s, pool + ':' + vm)).to be_nil
        subject.move_pending_vm_to_ready(vm, pool, host)
        expect(redis.hget('vmpooler__boot__' + Date.today.to_s, pool + ':' + vm)).to_not be_nil
        # TODO Should we inspect the value to see if it's valid?
      end

      it 'should not determine boot timespan if clone start time not set' do
        expect(redis.hget('vmpooler__boot__' + Date.today.to_s, pool + ':' + vm)).to be_nil
        subject.move_pending_vm_to_ready(vm, pool, host)
        expect(redis.hget('vmpooler__boot__' + Date.today.to_s, pool + ':' + vm)).to eq("") # Possible implementation bug here. Should still be nil here
      end

      it 'should raise error if clone start time is not parsable' do
        redis.hset("vmpooler__vm__#{vm}", 'clone','iamnotparsable_asdate')
        expect{subject.move_pending_vm_to_ready(vm, pool, host)}.to raise_error(/iamnotparsable_asdate/)
      end
    end
  end

  describe '#check_ready_vm' do
    let(:ttl) { 0 }

    before do
      expect(subject).not_to be_nil
    end

    it 'calls _check_ready_vm' do
      expect(Thread).to receive(:new).and_yield
      expect(subject).to receive(:_check_ready_vm).with(vm, pool, ttl, provider)

      subject.check_ready_vm(vm, pool, ttl, provider)
    end
  end

  describe '#_check_ready_vm' do
    let(:ttl) { 0 }
    let(:host) { {} }

    before(:each) do
      create_ready_vm(pool,vm)
      config[:config] = {}
      config[:config]['vm_checktime'] = 15

      # Create a VM which is powered on
      host['hostname'] = vm
      host['powerstate'] = 'PoweredOn'
      allow(provider).to receive(:get_vm).with(pool,vm).and_return(host)
    end

    context 'a VM that does not need to be checked' do
      it 'should do nothing' do
        check_stamp = (Time.now - 60).to_s
        redis.hset("vmpooler__vm__#{vm}", 'check', check_stamp)
        expect(provider).to receive(:get_vm).exactly(0).times
        subject._check_ready_vm(vm, pool, ttl, provider)
        expect(redis.hget("vmpooler__vm__#{vm}", 'check')).to eq(check_stamp)
      end
    end

    context 'a VM that does not exist' do
      before do
        expect(provider).to receive(:get_vm).with(pool,vm).and_return(nil)
      end

      it 'should not set the current check timestamp' do
        expect(redis.hget("vmpooler__vm__#{vm}", 'check')).to be_nil
        subject._check_ready_vm(vm, pool, ttl, provider)
        expect(redis.hget("vmpooler__vm__#{vm}", 'check')).to be_nil
      end

      it 'should log a message' do
        expect(logger).to receive(:log).with('s', "[!] [#{pool}] '#{vm}' not found in inventory, removed from 'ready' queue")
        subject._check_ready_vm(vm, pool, ttl, provider)
      end

      it 'should remove the VM from the ready queue' do
        expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(true)
        subject._check_ready_vm(vm, pool, ttl, provider)
        expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(false)
      end
    end

    context 'a VM that has never been checked' do
      let(:last_check_date) { Date.new(2001,1,1).to_s }

      it 'should set the current check timestamp' do
        expect(redis.hget("vmpooler__vm__#{vm}", 'check')).to be_nil
        subject._check_ready_vm(vm, pool, ttl, provider)
        expect(redis.hget("vmpooler__vm__#{vm}", 'check')).to_not be_nil
      end
    end

    context 'a VM that needs to be checked' do
      let(:last_check_date) { Date.new(2001,1,1).to_s }
      before(:each) do
        redis.hset("vmpooler__vm__#{vm}", 'check',last_check_date)
      end

      it 'should set the current check timestamp' do
        expect(redis.hget("vmpooler__vm__#{vm}", 'check')).to eq(last_check_date)
        subject._check_ready_vm(vm, pool, ttl, provider)
        expect(redis.hget("vmpooler__vm__#{vm}", 'check')).to_not eq(last_check_date)
      end

      context 'and is ready' do
        before(:each) do
          expect(provider).to receive(:vm_ready?).with(pool, vm).and_return(true)
        end

        it 'should only set the next check interval' do
          subject._check_ready_vm(vm, pool, ttl, provider)
        end
      end

      context 'is turned off' do
        before(:each) do
          host['boottime'] = nil
          host['powerstate'] = 'PoweredOff'
        end

        it 'should move the VM to the completed queue' do
          expect(redis).to receive(:smove).with("vmpooler__ready__#{pool}", "vmpooler__completed__#{pool}", vm)

          subject._check_ready_vm(vm, pool, ttl, provider)
        end

        it 'should move the VM to the completed queue in Redis' do
          expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(true)
          expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(false)
          subject._check_ready_vm(vm, pool, ttl, provider)
          expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(false)
          expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(true)
        end

        it 'should log messages about being powered off' do
          expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' appears to be powered off, removed from 'ready' queue")

          subject._check_ready_vm(vm, pool, ttl, provider)
        end
      end

      context 'is turned on, a name mismatch' do
        before(:each) do
          host['hostname'] = 'different_name'
        end

        it 'should move the VM to the completed queue' do
          expect(redis).to receive(:smove).with("vmpooler__ready__#{pool}", "vmpooler__completed__#{pool}", vm)

          subject._check_ready_vm(vm, pool, ttl, provider)
        end

        it 'should move the VM to the completed queue in Redis' do
          expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(true)
          expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(false)
          subject._check_ready_vm(vm, pool, ttl, provider)
          expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(false)
          expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(true)
        end

        it 'should log messages about being misnamed' do
          expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' has mismatched hostname, removed from 'ready' queue")

          subject._check_ready_vm(vm, pool, ttl, provider)
        end
      end

      context 'is turned on, with correct name and is not ready' do
        before(:each) do
          expect(provider).to receive(:vm_ready?).with(pool, vm).and_return(false)
        end

        it 'should move the VM to the completed queue' do
          expect(redis).to receive(:smove).with("vmpooler__ready__#{pool}", "vmpooler__completed__#{pool}", vm)

          subject._check_ready_vm(vm, pool, ttl, provider)
        end

        it 'should move the VM to the completed queue in Redis' do
          expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(true)
          expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(false)
          subject._check_ready_vm(vm, pool, ttl, provider)
          expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(false)
          expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(true)
        end

        it 'should log messages about being unreachable' do
          expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' is unreachable, removed from 'ready' queue")

          subject._check_ready_vm(vm, pool, ttl, provider)
        end
      end
    end
  end

  describe '#check_running_vm' do
    let(:provider) { double('provider') }
    let (:ttl) { 5 }

    before do
      expect(subject).not_to be_nil
    end

    it 'calls _check_running_vm' do
      expect(Thread).to receive(:new).and_yield
      expect(subject).to receive(:_check_running_vm).with(vm, pool, ttl, provider)

      subject.check_running_vm(vm, pool, ttl, provider)
    end
  end

  describe '#_check_running_vm' do
    let(:host) { {} }

    before do
      expect(subject).not_to be_nil
    end

    before(:each) do
      create_running_vm(pool,vm)

      # Create a VM which is powered on
      host['hostname'] = vm
      host['powerstate'] = 'PoweredOn'
      allow(provider).to receive(:get_vm).with(pool,vm).and_return(host)
    end

    it 'does nothing with a missing VM' do
      expect(provider).to receive(:get_vm).with(pool,vm).and_return(nil)
      expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
      subject._check_running_vm(vm, pool, timeout, provider)
      expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
    end

    context 'valid host' do
     it 'should not move VM when not poweredOn' do
        # I'm not sure this test is useful.  There is no codepath
        # in _check_running_vm that looks at Power State
        host['powerstate'] = 'PoweredOff'

        expect(logger).not_to receive(:log).with('d', "[!] [#{pool}] '#{vm}' appears to be powered off or dead")
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
        subject._check_running_vm(vm, pool, timeout, provider)
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
      end

      it 'should not move VM if it has no checkout time' do
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
        subject._check_running_vm(vm, pool, 0, provider)
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
      end

      it 'should not move VM if TTL is zero' do
        redis.hset("vmpooler__active__#{pool}", vm,(Time.now - timeout*60*60).to_s)
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
        subject._check_running_vm(vm, pool, 0, provider)
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
      end

      it 'should move VM when past TTL' do
        redis.hset("vmpooler__active__#{pool}", vm,(Time.now - timeout*60*60).to_s)
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
        expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(false)
        subject._check_running_vm(vm, pool, timeout, provider)
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(false)
        expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(true)
      end
    end
  end

  describe '#move_vm_queue' do
    let(:queue_from) { 'pending' }
    let(:queue_to) { 'completed' }
    let(:message) { 'message' }

    before do
      expect(subject).not_to be_nil
    end

    before(:each) do
      create_pending_vm(pool, vm, token)
    end

    it 'VM should be in the "from queue" before the move' do
      expect(redis.sismember("vmpooler__#{queue_from}__#{pool}",vm))
    end

    it 'VM should not be in the "from queue" after the move' do
      subject.move_vm_queue(pool, vm, queue_from, queue_to, message)
      expect(!redis.sismember("vmpooler__#{queue_from}__#{pool}",vm))
    end

    it 'VM should not be in the "to queue" before the move' do
      expect(!redis.sismember("vmpooler__#{queue_to}__#{pool}",vm))
    end

    it 'VM should be in the "to queue" after the move' do
      subject.move_vm_queue(pool, vm, queue_from, queue_to, message)
      expect(redis.sismember("vmpooler__#{queue_to}__#{pool}",vm))
    end

    it 'should log a message' do
      allow(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' #{message}")

      subject.move_vm_queue(pool, vm, queue_from, queue_to, message)
    end
  end

  describe '#clone_vm' do
    let (:pool_object) { { 'name' => pool } }

    before do
      expect(subject).not_to be_nil
      expect(Thread).to receive(:new).and_yield
    end

    it 'calls _clone_vm' do
      expect(subject).to receive(:_clone_vm).with(pool_object,provider)

      subject.clone_vm(pool_object,provider)
    end

    it 'logs a message if an error is raised' do
      allow(logger).to receive(:log)
      expect(logger).to receive(:log).with('s',"[!] [#{pool_object['name']}] failed while cloning VM with an error: MockError")
      expect(subject).to receive(:_clone_vm).with(pool_object,provider).and_raise('MockError')

      expect{subject.clone_vm(pool_object,provider)}.to raise_error(/MockError/)
    end
  end

  describe '#_clone_vm' do
    let (:pool_object) { { 'name' => pool } }

    before do
      expect(subject).not_to be_nil
    end

    let(:config) {
      YAML.load(<<-EOT
---
:config:
  prefix: "prefix"
EOT
      )
    }

    context 'with no errors during cloning' do
      before(:each) do
        expect(metrics).to receive(:timing).with(/clone\./,/0/)
        expect(provider).to receive(:create_vm).with(pool, String)
        allow(logger).to receive(:log)
      end

      it 'should create a cloning VM' do
        expect(redis.scard("vmpooler__pending__#{pool}")).to eq(0)

        subject._clone_vm(pool_object,provider)

        expect(redis.scard("vmpooler__pending__#{pool}")).to eq(1)
        # Get the new VM Name from the pending pool queue as it should be the only entry
        vm_name = redis.smembers("vmpooler__pending__#{pool}")[0]
        expect(redis.hget("vmpooler__vm__#{vm_name}", 'clone')).to_not be_nil
        expect(redis.hget("vmpooler__vm__#{vm_name}", 'template')).to eq(pool)
        expect(redis.hget("vmpooler__clone__#{Date.today.to_s}", "#{pool}:#{vm_name}")).to_not be_nil
        expect(redis.hget("vmpooler__vm__#{vm_name}", 'clone_time')).to_not be_nil
      end

      it 'should decrement the clone tasks counter' do
        redis.incr('vmpooler__tasks__clone')
        redis.incr('vmpooler__tasks__clone')
        expect(redis.get('vmpooler__tasks__clone')).to eq('2')
        subject._clone_vm(pool_object,provider)
        expect(redis.get('vmpooler__tasks__clone')).to eq('1')
      end

      it 'should log a message that is being cloned from a template' do
        expect(logger).to receive(:log).with('d',/\[ \] \[#{pool}\] Starting to clone '(.+)'/)

        subject._clone_vm(pool_object,provider)
      end

      it 'should log a message that it completed being cloned' do
        expect(logger).to receive(:log).with('s',/\[\+\] \[#{pool}\] '(.+)' cloned in [0-9.]+ seconds/)

        subject._clone_vm(pool_object,provider)
      end
    end

    context 'with an error during cloning' do
      before(:each) do
        expect(provider).to receive(:create_vm).with(pool, String).and_raise('MockError')
        allow(logger).to receive(:log)
      end

      it 'should not create a cloning VM' do
        expect(redis.scard("vmpooler__pending__#{pool}")).to eq(0)

        expect{subject._clone_vm(pool_object,provider)}.to raise_error(/MockError/)

        expect(redis.scard("vmpooler__pending__#{pool}")).to eq(0)
        # Get the new VM Name from the pending pool queue as it should be the only entry
        vm_name = redis.smembers("vmpooler__pending__#{pool}")[0]
        expect(vm_name).to be_nil
      end

      it 'should decrement the clone tasks counter' do
        redis.incr('vmpooler__tasks__clone')
        redis.incr('vmpooler__tasks__clone')
        expect(redis.get('vmpooler__tasks__clone')).to eq('2')
        expect{subject._clone_vm(pool_object,provider)}.to raise_error(/MockError/)
        expect(redis.get('vmpooler__tasks__clone')).to eq('1')
      end

      it 'should log messages that the clone failed' do
        expect(logger).to receive(:log).with('s', /\[!\] \[#{pool}\] '(.+)' clone failed with an error: MockError/)

        expect{subject._clone_vm(pool_object,provider)}.to raise_error(/MockError/)
      end
    end
  end

  describe '#destroy_vm' do
    before do
      expect(subject).not_to be_nil
      expect(Thread).to receive(:new).and_yield
    end

    it 'calls _destroy_vm' do
      expect(subject).to receive(:_destroy_vm).with(vm,pool,provider)

      subject.destroy_vm(vm,pool,provider)
    end

    it 'logs a message if an error is raised' do
      allow(logger).to receive(:log)
      expect(logger).to receive(:log).with('d',"[!] [#{pool}] '#{vm}' failed while destroying the VM with an error: MockError")
      expect(subject).to receive(:_destroy_vm).with(vm,pool,provider).and_raise('MockError')

      expect{subject.destroy_vm(vm,pool,provider)}.to raise_error(/MockError/)
    end
  end

  describe "#_destroy_vm" do
    before(:each) do
      expect(subject).not_to be_nil

      create_completed_vm(vm,pool,true)

      allow(provider).to receive(:destroy_vm).with(pool,vm).and_return(true)

      # Set redis configuration
      config[:redis] = {}
      config[:redis]['data_ttl'] = 168
    end

    context 'when redis data_ttl is not specified in the configuration' do
      before(:each) do
        config[:redis]['data_ttl'] = nil
      end

      it 'should call redis expire with 0' do
        expect(redis.hget("vmpooler__vm__#{vm}", 'checkout')).to_not be_nil
        subject._destroy_vm(vm,pool,provider)
        expect(redis.hget("vmpooler__vm__#{vm}", 'checkout')).to be_nil
      end
    end

    context 'when there is no redis section in the configuration' do
      before(:each) do
        config[:redis] = nil
      end
      
      it 'should raise an error' do
        expect{ subject._destroy_vm(vm,pool,provider) }.to raise_error(NoMethodError)
      end
    end

    context 'when a VM does not exist' do
      before(:each) do
        # As per base_spec, destroy_vm will return true if the VM does not exist
        expect(provider).to receive(:destroy_vm).with(pool,vm).and_return(true)
      end

      it 'should not raise an error' do
        subject._destroy_vm(vm,pool,provider)
      end
    end

    context 'when the VM is destroyed without error' do
      it 'should log a message the VM was destroyed' do
        expect(logger).to receive(:log).with('s', /\[-\] \[#{pool}\] '#{vm}' destroyed in [0-9.]+ seconds/)
        allow(logger).to receive(:log)

        subject._destroy_vm(vm,pool,provider)
      end

      it 'should emit a timing metric' do
        expect(metrics).to receive(:timing).with("destroy.#{pool}", String)

        subject._destroy_vm(vm,pool,provider)
      end
    end

    context 'when the VM destruction raises an eror' do
      before(:each) do
        # As per base_spec, destroy_vm will return true if the VM does not exist
        expect(provider).to receive(:destroy_vm).with(pool,vm).and_raise('MockError')
      end

      it 'should not log a message the VM was destroyed' do
        expect(logger).to receive(:log).with('s', /\[-\] \[#{pool}\] '#{vm}' destroyed in [0-9.]+ seconds/).exactly(0).times
        allow(logger).to receive(:log)

        expect{ subject._destroy_vm(vm,pool,provider) }.to raise_error(/MockError/)
      end

      it 'should not emit a timing metric' do
        expect(metrics).to receive(:timing).with("destroy.#{pool}", String).exactly(0).times

        expect{ subject._destroy_vm(vm,pool,provider) }.to raise_error(/MockError/)
      end
    end
  end

  describe '#create_vm_disk' do
    let(:provider) { double('provider') }
    let(:disk_size) { 15 }

    before do
      expect(subject).not_to be_nil
    end

    it 'calls _create_vm_disk' do
      expect(Thread).to receive(:new).and_yield
      expect(subject).to receive(:_create_vm_disk).with(pool, vm, disk_size, provider)

      subject.create_vm_disk(pool, vm, disk_size, provider)
    end
  end

  describe "#_create_vm_disk" do
    let(:disk_size) { '15' }

    before(:each) do
      expect(subject).not_to be_nil
      allow(logger).to receive(:log)

      create_running_vm(pool,vm,token)
    end

    context 'Given a VM that does not exist' do
      before(:each) do
        # As per base_spec, create_disk will raise if the VM does not exist
        expect(provider).to receive(:create_disk).with(pool,vm,disk_size.to_i).and_raise("VM #{vm} does not exist")
      end

      it 'should not update redis if the VM does not exist' do
        expect(redis).to receive(:hset).exactly(0).times
        expect{ subject._create_vm_disk(pool, vm, disk_size, provider) }.to raise_error(RuntimeError)
      end
    end

    context 'Given an invalid disk size' do
      [{ :description => 'is nil',                            :value => nil },
       { :description => 'is an empty string',                :value => '' },
       { :description => 'is less than 1',                    :value => '0' },
       { :description => 'cannot be converted to an integer', :value => 'abc123' },
      ].each do |testcase|
        it "should not attempt the create the disk if the disk size #{testcase[:description]}" do
          expect(provider).to receive(:create_disk).exactly(0).times
          expect{ subject._create_vm_disk(pool, vm, testcase[:value], provider) }.to raise_error(/Invalid disk size/)
        end
      end

      it 'should raise an error if the disk size is a Fixnum' do
        expect(redis).to receive(:hset).exactly(0).times
        expect{ subject._create_vm_disk(pool, vm, 10, provider) }.to raise_error(NoMethodError,/empty?/)
      end
    end

    context 'Given a successful disk creation' do
      before(:each) do
        expect(provider).to receive(:create_disk).with(pool,vm,disk_size.to_i).and_return(true)
      end

      it 'should log a message' do
        expect(logger).to receive(:log).with('s', "[ ] [disk_manager] '#{vm}' is attaching a #{disk_size}gb disk")
        expect(logger).to receive(:log).with('s', /\[\+\] \[disk_manager\] '#{vm}' attached #{disk_size}gb disk in 0.[\d]+ seconds/)

        subject._create_vm_disk(pool, vm, disk_size, provider)
      end

      it 'should update redis information when attaching the first disk' do
        subject._create_vm_disk(pool, vm, disk_size, provider)
        expect(redis.hget("vmpooler__vm__#{vm}", 'disk')).to eq("+#{disk_size}gb")
      end

      it 'should update redis information when attaching the additional disks' do
        initial_disks = '+10gb:+20gb'
        redis.hset("vmpooler__vm__#{vm}", 'disk', initial_disks)

        subject._create_vm_disk(pool, vm, disk_size, provider)
        expect(redis.hget("vmpooler__vm__#{vm}", 'disk')).to eq("#{initial_disks}:+#{disk_size}gb")
      end
    end

    context 'Given a failed disk creation' do
      before(:each) do
        expect(provider).to receive(:create_disk).with(pool,vm,disk_size.to_i).and_return(false)
      end

      it 'should not update redis information' do
        expect(redis).to receive(:hset).exactly(0).times

        subject._create_vm_disk(pool, vm, disk_size, provider)
        expect(redis.hget("vmpooler__vm__#{vm}", 'disk')).to be_nil
      end

      it 'should log a message' do
        expect(logger).to receive(:log).with('s', "[+] [disk_manager] '#{vm}' failed to attach disk")

        subject._create_vm_disk(pool, vm, disk_size, provider)
      end
    end
  end

  describe '#create_vm_snapshot' do
    let(:snapshot_name) { 'snapshot' }

    before do
      expect(subject).not_to be_nil
    end

    it 'calls _create_vm_snapshot' do
      expect(Thread).to receive(:new).and_yield
      expect(subject).to receive(:_create_vm_snapshot).with(pool, vm, snapshot_name, provider)

      subject.create_vm_snapshot(pool, vm, snapshot_name, provider)
    end
  end

  describe '#_create_vm_snapshot' do
    let(:snapshot_name) { 'snapshot1' }

    before do
      expect(subject).not_to be_nil
    end

    before(:each) do
      create_running_vm(pool,vm,token)
    end

    context 'Given a Pool that does not exist' do
      let(:missing_pool) { 'missing_pool' }

      before(:each) do
        expect(provider).to receive(:create_snapshot).with(missing_pool, vm, snapshot_name).and_raise("Pool #{missing_pool} not found")
      end

      it 'should not update redis' do
        expect(redis.hget("vmpooler__vm__#{vm}", "snapshot:#{snapshot_name}")).to be_nil
        expect{ subject._create_vm_snapshot(missing_pool, vm, snapshot_name, provider) }.to raise_error("Pool #{missing_pool} not found")
        expect(redis.hget("vmpooler__vm__#{vm}", "snapshot:#{snapshot_name}")).to be_nil
      end
    end

    context 'Given a VM that does not exist' do
      let(:missing_vm) { 'missing_vm' }
      before(:each) do
        expect(provider).to receive(:create_snapshot).with(pool, missing_vm, snapshot_name).and_raise("VM #{missing_vm} not found")
      end

      it 'should not update redis' do
        expect(redis.hget("vmpooler__vm__#{vm}", "snapshot:#{snapshot_name}")).to be_nil
        expect{ subject._create_vm_snapshot(pool, missing_vm, snapshot_name, provider) }.to raise_error("VM #{missing_vm} not found")
        expect(redis.hget("vmpooler__vm__#{vm}", "snapshot:#{snapshot_name}")).to be_nil
      end
    end

    context 'Given a snapshot creation that succeeds' do
      before(:each) do
        expect(provider).to receive(:create_snapshot).with(pool, vm, snapshot_name).and_return(true)
      end

      it 'should log messages' do
        expect(logger).to receive(:log).with('s', "[ ] [snapshot_manager] 'Attempting to snapshot #{vm} in pool #{pool}")
        expect(logger).to receive(:log).with('s', /\[\+\] \[snapshot_manager\] '#{vm}' snapshot created in 0.[\d]+ seconds/)

        subject._create_vm_snapshot(pool, vm, snapshot_name, provider)
      end

      it 'should add snapshot redis information' do
        expect(redis.hget("vmpooler__vm__#{vm}", "snapshot:#{snapshot_name}")).to be_nil
        subject._create_vm_snapshot(pool, vm, snapshot_name, provider)
        expect(redis.hget("vmpooler__vm__#{vm}", "snapshot:#{snapshot_name}")).to_not be_nil
      end
    end

    context 'Given a snapshot creation that fails' do
      before(:each) do
        expect(provider).to receive(:create_snapshot).with(pool, vm, snapshot_name).and_return(false)
      end

      it 'should log messages' do
        expect(logger).to receive(:log).with('s', "[ ] [snapshot_manager] 'Attempting to snapshot #{vm} in pool #{pool}")
        expect(logger).to receive(:log).with('s', "[+] [snapshot_manager] Failed to snapshot '#{vm}'")

        subject._create_vm_snapshot(pool, vm, snapshot_name, provider)
      end

      it 'should not update redis' do
        expect(redis.hget("vmpooler__vm__#{vm}", "snapshot:#{snapshot_name}")).to be_nil
        subject._create_vm_snapshot(pool, vm, snapshot_name, provider)
        expect(redis.hget("vmpooler__vm__#{vm}", "snapshot:#{snapshot_name}")).to be_nil
      end
    end
  end

  describe '#revert_vm_snapshot' do
    let(:snapshot_name) { 'snapshot' }

    before do
      expect(subject).not_to be_nil
    end

    it 'calls _revert_vm_snapshot' do
      expect(Thread).to receive(:new).and_yield
      expect(subject).to receive(:_revert_vm_snapshot).with(pool, vm, snapshot_name, provider)

      subject.revert_vm_snapshot(pool, vm, snapshot_name, provider)
    end
  end

  describe '#_revert_vm_snapshot' do
    let(:snapshot_name) { 'snapshot1' }

    before do
      expect(subject).not_to be_nil
    end

    context 'Given a Pool that does not exist' do
      let(:missing_pool) { 'missing_pool' }

      before(:each) do
        expect(provider).to receive(:revert_snapshot).with(missing_pool, vm, snapshot_name).and_raise("Pool #{missing_pool} not found")
      end

      it 'should not log a result message' do
        expect(logger).to receive(:log).with('s', /\[\+\] \[snapshot_manager\] '#{vm}' reverted to snapshot '#{snapshot_name}' in 0.[\d]+ seconds/).exactly(0).times
        expect(logger).to receive(:log).with('s', "[+] [snapshot_manager] Failed to revert #{vm}' in pool #{missing_pool} to snapshot '#{snapshot_name}'").exactly(0).times

        expect{ subject._revert_vm_snapshot(missing_pool, vm, snapshot_name, provider) }.to raise_error("Pool #{missing_pool} not found")
      end
    end

    context 'Given a VM that does not exist' do
      let(:missing_vm) { 'missing_vm' }
      before(:each) do
        expect(provider).to receive(:revert_snapshot).with(pool, missing_vm, snapshot_name).and_raise("VM #{missing_vm} not found")
      end

      it 'should not log a result message' do
        expect(logger).to receive(:log).with('s', /\[\+\] \[snapshot_manager\] '#{missing_vm}' reverted to snapshot '#{snapshot_name}' in 0.[\d]+ seconds/).exactly(0).times
        expect(logger).to receive(:log).with('s', "[+] [snapshot_manager] Failed to revert #{missing_vm}' in pool #{pool} to snapshot '#{snapshot_name}'").exactly(0).times

        expect{ subject._revert_vm_snapshot(pool, missing_vm, snapshot_name, provider) }.to raise_error("VM #{missing_vm} not found")
      end
    end

    context 'Given a snapshot revert that succeeds' do
      before(:each) do
        expect(provider).to receive(:revert_snapshot).with(pool, vm, snapshot_name).and_return(true)
      end

      it 'should log success messages' do
        expect(logger).to receive(:log).with('s', "[ ] [snapshot_manager] 'Attempting to revert #{vm}' in pool #{pool} to snapshot '#{snapshot_name}'")
        expect(logger).to receive(:log).with('s', /\[\+\] \[snapshot_manager\] '#{vm}' reverted to snapshot '#{snapshot_name}' in 0.[\d]+ seconds/)

        subject._revert_vm_snapshot(pool, vm, snapshot_name, provider)
      end

      it 'should return true' do
        expect(subject._revert_vm_snapshot(pool, vm, snapshot_name, provider)).to be true
      end
    end

    context 'Given a snapshot creation that fails' do
      before(:each) do
        expect(provider).to receive(:revert_snapshot).with(pool, vm, snapshot_name).and_return(false)
      end

      it 'should log failure messages' do
        expect(logger).to receive(:log).with('s', "[ ] [snapshot_manager] 'Attempting to revert #{vm}' in pool #{pool} to snapshot '#{snapshot_name}'")
        expect(logger).to receive(:log).with('s', "[+] [snapshot_manager] Failed to revert #{vm}' in pool #{pool} to snapshot '#{snapshot_name}'")

        subject._revert_vm_snapshot(pool, vm, snapshot_name, provider)
      end

      it 'should return false' do
        expect(subject._revert_vm_snapshot(pool, vm, snapshot_name, provider)).to be false
      end
    end
  end

  describe '#get_pool_name_for_vm' do
    context 'Given a valid VM' do
      before(:each) do
        create_running_vm(pool, vm, token)
      end

      it 'should return the pool name' do
        expect(subject.get_pool_name_for_vm(vm)).to eq(pool)
      end
    end

    context 'Given an invalid VM' do
      it 'should return nil' do
        expect(subject.get_pool_name_for_vm('does_not_exist')).to be_nil
      end
    end
  end

  describe '#get_provider_for_pool' do
    let(:provider_name) { 'mock_provider' }

    before do
      expect(subject).not_to be_nil
      # Inject mock provider into global variable - Note this is a code smell
      $providers = { provider_name => provider }
    end

    after(:each) do
      # Reset the global variable - Note this is a code smell
      $providers = nil
    end

    context 'Given a pool name which does not exist' do
      let(:config) { YAML.load(<<-EOT
---
:config:
:providers:
  :mock:
:pools:
  - name: '#{pool}'
    size: 1
EOT
      )}

      it 'should return nil' do
        expect(subject.get_provider_for_pool('pool_does_not_exist')).to be_nil
      end
    end

    context 'Given a pool which does not have a provider' do
      let(:config) { YAML.load(<<-EOT
---
:config:
:providers:
  :mock:
:pools:
  - name: '#{pool}'
    size: 1
EOT
      )}

      it 'should return nil' do
        expect(subject.get_provider_for_pool(pool)).to be_nil
      end
    end

    context 'Given a pool which uses an invalid provider' do
      let(:config) { YAML.load(<<-EOT
---
:config:
:providers:
  :mock:
:pools:
  - name: '#{pool}'
    size: 1
    provider: 'does_not_exist'
EOT
      )}

      it 'should return nil' do
        expect(subject.get_provider_for_pool(pool)).to be_nil
      end
    end

    context 'Given a pool which uses a valid provider' do
      let(:config) { YAML.load(<<-EOT
---
:config:
:providers:
  :mock:
:pools:
  - name: '#{pool}'
    size: 1
    provider: #{provider_name}
EOT
      )}

      it 'should return a provider object' do
        result = subject.get_provider_for_pool(pool)
        expect(result).to_not be_nil
        expect(result.name).to eq(provider_name)
      end
    end
  end

  describe '#check_disk_queue' do
    let(:threads) {[]}

    before(:each) do
      expect(Thread).to receive(:new).and_yield
      allow(subject).to receive(:_check_disk_queue)
    end

    it 'should log the disk manager is starting' do
      expect(logger).to receive(:log).with('d', "[*] [disk_manager] starting worker thread")

      expect($threads.count).to be(0)
      subject.check_disk_queue(1,0)
      expect($threads.count).to be(1)
    end

    it 'should add the manager to the global thread list' do
      # Note - Ruby core types are not necessarily thread safe
      expect($threads.count).to be(0)
      subject.check_disk_queue(1,0)
      expect($threads.count).to be(1)
    end

    it 'should call _check_disk_queue' do
      expect(subject).to receive(:_check_disk_queue).with(no_args)

      subject.check_disk_queue(1,0)
    end

    context 'delays between loops' do
      let(:maxloop) { 2 }
      let(:loop_delay) { 1 }
      # Note a maxloop of zero can not be tested as it never terminates

      it 'defaults to 5 second loop delay' do
        expect(subject).to receive(:sleep).with(5).exactly(maxloop).times
        subject.check_disk_queue(maxloop)
      end

      it 'when a non-default loop delay is specified' do
        expect(subject).to receive(:sleep).with(loop_delay).exactly(maxloop).times

        subject.check_disk_queue(maxloop,loop_delay)
      end
    end

    context 'loops specified number of times (5)' do
      let(:maxloop) { 5 }
      # Note a maxloop of zero can not be tested as it never terminates

      after(:each) do
        # Reset the global variable - Note this is a code smell
        $threads = nil
      end

      it 'should call _check_disk_queue 5 times' do
        expect(subject).to receive(:_check_disk_queue).with(no_args).exactly(maxloop).times

        subject.check_disk_queue(maxloop,0)
      end
    end
  end

  describe '#_check_disk_queue' do
    before do
      expect(subject).not_to be_nil
    end

    context 'when no VMs in the queue' do
      it 'should not call create_vm_disk' do
        expect(subject).to receive(:create_vm_disk).exactly(0).times
        subject._check_disk_queue
      end
    end

    context 'when VM in the queue does not exist' do
      before(:each) do
        disk_task_vm(vm,"snapshot_#{vm}")
      end

      it 'should log an error' do
        expect(logger).to receive(:log).with('s', /Unable to determine which pool #{vm} is a member of/)

        subject._check_disk_queue
      end

      it 'should not call create_vm_disk' do
        expect(subject).to receive(:create_vm_disk).exactly(0).times

        subject._check_disk_queue
      end
    end

    context 'when specified provider does not exist' do
      before(:each) do
        disk_task_vm(vm,"snapshot_#{vm}")
        create_running_vm(pool, vm, token)
        expect(subject).to receive(:get_provider_for_pool).and_return(nil)
      end

      it 'should log an error' do
        expect(logger).to receive(:log).with('s', /Missing Provider for/)

        subject._check_disk_queue
      end

      it 'should not call create_vm_disk' do
        expect(subject).to receive(:create_vm_disk).exactly(0).times

        subject._check_disk_queue
      end
    end

    context 'when multiple VMs in the queue' do
      before(:each) do
        ['vm1', 'vm2', 'vm3'].each do |vm_name|
          disk_task_vm(vm_name,"snapshot_#{vm_name}")
          create_running_vm(pool, vm_name, token)
        end

        allow(subject).to receive(:get_provider_for_pool).with(pool).and_return(provider)
      end

      it 'should call create_vm_disk once' do
        expect(subject).to receive(:create_vm_disk).exactly(1).times
        subject._check_disk_queue
      end

      it 'should create the disk for the first VM in the queue' do
        expect(subject).to receive(:create_vm_disk).with(pool,'vm1','snapshot_vm1',provider)
        subject._check_disk_queue
      end

      it 'should log an error if one occurs' do
        expect(subject).to receive(:create_vm_disk).and_raise(RuntimeError,'MockError')
        expect(logger).to receive(:log).with('s', "[!] [disk_manager] disk creation appears to have failed: MockError")
        subject._check_disk_queue
      end
    end
  end

  describe '#check_snapshot_queue' do
    let(:threads) {[]}

    before(:each) do
      expect(Thread).to receive(:new).and_yield
      allow(subject).to receive(:_check_snapshot_queue).with(no_args)
    end

    it 'should log the snapshot manager is starting' do
      expect(logger).to receive(:log).with('d', "[*] [snapshot_manager] starting worker thread")

      expect($threads.count).to be(0)
      subject.check_snapshot_queue(1,0)
      expect($threads.count).to be(1)
    end

    it 'should add the manager to the global thread list' do
      # Note - Ruby core types are not necessarily thread safe
      expect($threads.count).to be(0)
      subject.check_snapshot_queue(1,0)
      expect($threads.count).to be(1)
    end

    it 'should call _check_snapshot_queue' do
      expect(subject).to receive(:_check_snapshot_queue).with(no_args)

      subject.check_snapshot_queue(1,0)
    end

    context 'delays between loops' do
      let(:maxloop) { 2 }
      let(:loop_delay) { 1 }
      # Note a maxloop of zero can not be tested as it never terminates

      it 'defaults to 5 second loop delay' do
        expect(subject).to receive(:sleep).with(5).exactly(maxloop).times
        subject.check_snapshot_queue(maxloop)
      end

      it 'when a non-default loop delay is specified' do
        expect(subject).to receive(:sleep).with(loop_delay).exactly(maxloop).times

        subject.check_snapshot_queue(maxloop,loop_delay)
      end
    end

    context 'loops specified number of times (5)' do
      let(:maxloop) { 5 }
      # Note a maxloop of zero can not be tested as it never terminates

      after(:each) do
        # Reset the global variable - Note this is a code smell
        $threads = nil
      end

      it 'should call _check_snapshot_queue 5 times' do
        expect(subject).to receive(:_check_snapshot_queue).with(no_args).exactly(maxloop).times

        subject.check_snapshot_queue(maxloop,0)
      end
    end
  end

  describe '#_check_snapshot_queue' do
    before do
      expect(subject).not_to be_nil
    end

    context 'vmpooler__tasks__snapshot queue' do
      context 'when no VMs in the queue' do
        it 'should not call create_vm_snapshot' do
          expect(subject).to receive(:create_vm_snapshot).exactly(0).times
          subject._check_snapshot_queue
        end
      end

      context 'when VM in the queue does not exist' do
        before(:each) do
          snapshot_vm(vm,"snapshot_#{vm}")
        end

        it 'should log an error' do
          expect(logger).to receive(:log).with('s', /Unable to determine which pool #{vm} is a member of/)

          subject._check_snapshot_queue
        end

        it 'should not call create_vm_snapshot' do
          expect(subject).to receive(:create_vm_snapshot).exactly(0).times

          subject._check_snapshot_queue
        end
      end

      context 'when specified provider does not exist' do
        before(:each) do
          snapshot_vm(vm,"snapshot_#{vm}")
          create_running_vm(pool, vm, token)
          expect(subject).to receive(:get_provider_for_pool).and_return(nil)
        end

        it 'should log an error' do
          expect(logger).to receive(:log).with('s', /Missing Provider for/)

          subject._check_snapshot_queue
        end

        it 'should not call create_vm_snapshot' do
          expect(subject).to receive(:create_vm_snapshot).exactly(0).times

          subject._check_snapshot_queue
        end
      end

      context 'when multiple VMs in the queue' do
        before(:each) do
          ['vm1', 'vm2', 'vm3'].each do |vm_name|
            snapshot_vm(vm_name,"snapshot_#{vm_name}")
            create_running_vm(pool, vm_name, token)
          end

          allow(subject).to receive(:get_provider_for_pool).with(pool).and_return(provider)
        end

        it 'should call create_vm_snapshot once' do
          expect(subject).to receive(:create_vm_snapshot).exactly(1).times
          subject._check_snapshot_queue
        end

        it 'should snapshot the first VM in the queue' do
          expect(subject).to receive(:create_vm_snapshot).with(pool,'vm1','snapshot_vm1',provider)
          subject._check_snapshot_queue
        end

        it 'should log an error if one occurs' do
          expect(subject).to receive(:create_vm_snapshot).and_raise(RuntimeError,'MockError')
          expect(logger).to receive(:log).with('s', "[!] [snapshot_manager] snapshot create appears to have failed: MockError")
          subject._check_snapshot_queue
        end
      end
    end

    context 'vmpooler__tasks__snapshot-revert queue' do
      context 'when no VMs in the queue' do
        it 'should not call revert_vm_snapshot' do
          expect(subject).to receive(:revert_vm_snapshot).exactly(0).times
          subject._check_snapshot_queue
        end
      end

      context 'when VM in the queue does not exist' do
        before(:each) do
          snapshot_revert_vm(vm,"snapshot_#{vm}")
        end

        it 'should log an error' do
          expect(logger).to receive(:log).with('s', /Unable to determine which pool #{vm} is a member of/)

          subject._check_snapshot_queue
        end

        it 'should not call revert_vm_snapshot' do
          expect(subject).to receive(:revert_vm_snapshot).exactly(0).times

          subject._check_snapshot_queue
        end
      end

      context 'when specified provider does not exist' do
        before(:each) do
          snapshot_revert_vm(vm,"snapshot_#{vm}")
          create_running_vm(pool, vm, token)
          expect(subject).to receive(:get_provider_for_pool).and_return(nil)
        end

        it 'should log an error' do
          expect(logger).to receive(:log).with('s', /Missing Provider for/)

          subject._check_snapshot_queue
        end

        it 'should not call revert_vm_snapshot' do
          expect(subject).to receive(:revert_vm_snapshot).exactly(0).times

          subject._check_snapshot_queue
        end
      end

      context 'when multiple VMs in the queue' do
        before(:each) do
          ['vm1', 'vm2', 'vm3'].each do |vm_name|
            snapshot_revert_vm(vm_name,"snapshot_#{vm_name}")
            create_running_vm(pool, vm_name, token)
          end

          allow(subject).to receive(:get_provider_for_pool).with(pool).and_return(provider)
        end

        it 'should call revert_vm_snapshot once' do
          expect(subject).to receive(:revert_vm_snapshot).exactly(1).times
          subject._check_snapshot_queue
        end

        it 'should snapshot the first VM in the queue' do
          expect(subject).to receive(:revert_vm_snapshot).with(pool,'vm1','snapshot_vm1',provider)
          subject._check_snapshot_queue
        end

        it 'should log an error if one occurs' do
          expect(subject).to receive(:revert_vm_snapshot).and_raise(RuntimeError,'MockError')
          expect(logger).to receive(:log).with('s', "[!] [snapshot_manager] snapshot revert appears to have failed: MockError")
          subject._check_snapshot_queue
        end
      end
    end
  end


  describe '#get_clusters' do

    context 'with a single cluster configured' do
      let(:config) {
        YAML.load(<<-EOT
---
:config:
  task_limit: 10
  clone_target: 'cluster1'
:pools:
  - name: #{pool}
    size: 10
EOT
        )
      }
      let(:clusters) { ['cluster1'] }

      it 'should return clusters configured' do
        expect(subject).to receive(:get_clusters).with(config).and_return(clusters)
        subject.get_clusters(config)
      end
    end

    context 'with clusters specified more than once' do
      let(:config) {
        YAML.load(<<-EOT
---
:config:
  task_limit: 10
  clone_target: 'cluster1'
:pools:
  - name: #{pool}
    size: 10
    clone_target: 'cluster1'
  - name: #{pool}2
    size: 10
    clone_target: 'cluster2'
EOT
        )
      }
      let(:clusters) { ['cluster1', 'cluster2'] }

      it 'should not return duplicates when a cluster is specified more than once' do
        expect(subject).to receive(:get_clusters).with(config).and_return(clusters)
        subject.get_clusters(config)
      end
    end

    context 'with no clone_target configured' do
      let(:config) {
        YAML.load(<<-EOT
---
:config:
  task_limit: 10
EOT
        )
      }

      it 'should return nil when no clusters are configured' do
        expect(subject).to receive(:get_clusters).with(config).and_return(nil)

        subject.get_clusters(config)
      end
    end
  end

  describe '#select_hosts' do

    let(:config) {
      YAML.load(<<-EOT
---
:config:
  task_limit: 10
  clone_target: 'cluster1'
:pools:
  - name: #{pool}
    size: 10
EOT
      )
    }
    let(:provider_hosts) {
      {
        'check_time_start' => Time.now - 30,
        'check_time_finished' => Time.now,
        'clusters' => {
          'cluster1' => {
            'hosts' => [ 'host1' ],
            'architectures' => { 'v3' => ['host1'] },
            'all_hosts' => ['host1']
          }
        }
      }
    }
    let(:clusters) { ['cluster1'] }

    before(:each) do
      $provider_hosts = provider_hosts
    end

    # Populate the $provider_hosts variable
    it 'should set the check_time_start key' do
      expect($provider_hosts).to have_key('check_time_start')
      expect(provider).to receive(:select_target_hosts).with(clusters).and_return(provider_hosts)
      subject.select_hosts(provider)
    end

    it 'should set the check_time_finished key' do
      expect($provider_hosts).to have_key('check_time_finished')
      expect(provider).to receive(:select_target_hosts).with(clusters).and_return(provider_hosts)
      subject.select_hosts(provider)
    end

    it 'should run select_target_hosts' do
      expect(provider).to receive(:select_target_hosts).with(clusters).and_return(provider_hosts)
      subject.select_hosts(provider)
    end

    it "should set $provider_hosts['cluster'] to hosts_hash['cluster']" do

    end
  end


  describe '#run_select_hosts' do
    let(:config) {
      YAML.load(<<-EOT
---
:config:
  task_limit: 10
  clone_target: 'cluster1'
:pools:
  - name: #{pool}
    size: 10
EOT
      )
    }
    let(:provider_hosts) {
      {
        'check_time_finished' => Time.now,
        'clusters' => {
          'cluster1' => {
            'hosts' => [ 'host1' ],
            'architectures' => { 'v3' => ['host1'] },
            'all_hosts' => ['host1']
          }
        }
      }
    }
    let(:provider) { double('provider') }
    let(:pool_object) { config[:pools][0] }
    let(:pool_name) { pool_object['name'] }
    let(:maxage) { 60 }
    let(:clusters) { ['cluster1'] }
    # A wrapper to ensure select_hosts is not run more than once, and results are present

    context '$provider_hosts has key checking' do
      before(:each) do
        $provider_hosts = provider_hosts
        $provider_hosts['checking'] = true
      end

      it 'runs wait_for_host_selection' do
        expect(subject).to receive(:wait_for_host_selection).with(pool_name)
        subject.run_select_hosts(provider, pool_name, provider_hosts)
      end

    end

    context '$provider_hosts has check_time_finished key and is 100 seconds old' do
      before(:each) do
        $provider_hosts = provider_hosts
        $provider_hosts['check_time_finished'] = Time.now - 100
      end

      it 'runs select_hosts' do
        expect(provider).to receive(:select_target_hosts).with(clusters).and_return(provider_hosts)

        subject.run_select_hosts(provider, pool_name, provider_hosts, maxage)
      end
    end

    context '$provider_hosts has check_time_finished key 10 seconds old' do
      before(:each) do
        $provider_hosts = provider_hosts
        $provider_hosts['check_time_finished'] = Time.now - 10
      end

      it 'does not run select_hosts' do
        expect(subject).not_to receive(:select_hosts)

        subject.run_select_hosts(provider, pool_name, provider_hosts)
      end
    end

    context '$provider_hosts does not have key check_time_finished' do
      let(:provider_hosts) { { } }

      before(:each) do
        $provider_hosts = provider_hosts
      end

      it 'runs select_hosts' do
        expect(subject).to receive(:select_hosts).with(provider)

        subject.run_select_hosts(provider, pool_name, provider_hosts)
      end
    end
  end


  describe '#wait_for_host_selection' do
    let(:loop_delay) { 0 }
    let(:max_age) { 60 }

    context 'when provider_hosts does not have key check_time_finished and maxloop is one' do
      let(:provider_hosts) { { } }
      let(:maxloop) { 1 }

      before(:each) do
        $provider_hosts = provider_hosts
      end

      it 'sleeps for loop_delay once' do
        expect(subject).to receive(:sleep).with(loop_delay).exactly(maxloop).times

        subject.wait_for_host_selection(pool, maxloop, loop_delay, max_age)
      end
    end

    context 'when provider_hosts does not have key check_time_finished and maxloop is two' do
      let(:provider_hosts) { { } }
      let(:maxloop) { 2 }

      it 'sleeps for loop_delay two times' do
        expect(subject).to receive(:sleep).with(loop_delay).exactly(maxloop).times

        subject.wait_for_host_selection(pool, maxloop, loop_delay, max_age)
      end
    end

    context 'when $provider_hosts has key check_time_finished and age is greater than max_age' do
      let(:provider_hosts) { { 'check_time_finished' => Time.now - 100 } }
      let(:maxloop) { 1 }

      it 'sleeps for loop_delay once' do
        expect(subject).to receive(:sleep).with(loop_delay).exactly(maxloop).times

        subject.wait_for_host_selection(pool, maxloop, loop_delay, max_age)
      end
    end
  end


  describe '#select_next_host' do

    let(:hosts_hash) { }
    let(:cluster_name) { 'cluster1' }
    let(:architecture) { 'v3' }
    let(:target_host) { 'host1' }

    context 'with a list of hosts available' do
      let(:provider_hosts) {
        {
          'check_time_finished' => Time.now,
          'clusters' => {
            'cluster1' => {
              'architectures' => { 'v3' => ['host1', 'host2'] }
            }
          }
        }
      }

      before(:each) do
        $provider_hosts = provider_hosts
      end

      it 'returns the first host from the target cluster and architecture list' do
        expect(subject).to receive(:select_next_host)

        subject.select_next_host(cluster_name, architecture, provider_hosts)
      end

      it 'appends the selected host to the end of target_hash' do
        expect(subject).to receive(:select_next_host).and_return(target_host)

        subject.select_next_host(cluster_name, architecture, provider_hosts)
      end
    end

    context 'with no hosts available' do
      let(:provider_hosts) {
        {
          'check_time_finished' => Time.now,
          'clusters' => {
            'cluster1' => { 'architectures' => { 'v3' => [ ] } }
          }
        }
      }
      it 'returns when host is nil' do
        expect(subject).to receive(:select_next_host).and_return(nil)

        subject.select_next_host(cluster_name, architecture, provider_hosts)
      end
    end

  end


  describe '#migration_limit' do
    # This is a little confusing.  Is this supposed to return a boolean
    # or integer type?
    [false,0].each do |testvalue|
      it "should return false for an input of #{testvalue}" do
        expect(subject.migration_limit(testvalue)).to eq(false)
      end
    end

    [1,32768].each do |testvalue|
      it "should return #{testvalue} for an input of #{testvalue}" do
        expect(subject.migration_limit(testvalue)).to eq(testvalue)
      end
    end

    [-1,-32768].each do |testvalue|
      it "should return nil for an input of #{testvalue}" do
        expect(subject.migration_limit(testvalue)).to be_nil
      end
    end
  end

  describe '#migrate_vm' do
    before(:each) do
      expect(subject).not_to be_nil
      expect(Thread).to receive(:new).and_yield
    end

    it 'calls _migrate_vm' do
      expect(subject).to receive(:_migrate_vm).with(vm, pool, provider, $provider_hosts)

      subject.migrate_vm(vm, pool, provider)
    end

      let(:provider_hosts) {
        {
          'check_time_finished' => Time.now,
          'clusters' => {
            'cluster1' => {
              'hosts' => ['host1'],
              'architectures' => { 'v3' => ['host1'] },
              'all_hosts' => ['host1']
            }
          }
        }
      }

    context 'When an error is raised' do
      before(:each) do
        expect(subject).to receive(:_migrate_vm).with(vm, pool, provider, $provider_hosts).and_raise('MockError')
      end

      it 'logs a message' do
        allow(logger).to receive(:log)
        expect(logger).to receive(:log).with('s', "[x] [#{pool}] '#{vm}' migration failed with an error: MockError")

        subject.migrate_vm(vm, pool, provider)
      end

      it 'should attempt to remove from vmpooler_migration queue' do
        expect(subject).to receive(:remove_vmpooler_migration_vm).with(pool, vm)

        subject.migrate_vm(vm, pool, provider)
      end
    end
  end

  describe "#_migrate_vm" do
    let(:vm_parent_hostname) { 'host1' }
    let(:cluster_name) { 'cluster1' }
    let(:clusters) { [cluster_name] }
    let(:host_architecture) { 'v3' }
    let(:config) {
      YAML.load(<<-EOT
---
:config:
  migration_limit: 5
  clone_target: 'cluster1'
EOT
      )
    }
    let(:provider_hosts) {
      {
        'check_time_finished' => Time.now,
        'clusters' => {
          'cluster1' => {
            'hosts' => ['host1'],
            'architectures' => { 'v3' => ['host1'] },
            'all_hosts' => ['host1']
          }
        }
      }
    }

    before(:each) do
      expect(subject).not_to be_nil
      allow(provider).to receive(:get_vm_host).with(pool, vm).and_return(vm_parent_hostname)
    end

    context 'when an error occurs trying to retrieve the current host' do
      before(:each) do
        expect(provider).to receive(:get_vm_host).with(pool, vm).and_raise(RuntimeError,'MockError')
      end

      it 'should raise an error' do
        expect{ subject._migrate_vm(vm, pool, provider) }.to raise_error('MockError')
      end
    end

    context 'when the current host can not be determined' do
      before(:each) do
        expect(provider).to receive(:get_vm_host).with(pool, vm).and_return(nil)
      end

      it 'should raise an error' do
        expect(provider).to receive(:get_vm_cluster).with(pool, vm).and_return(cluster_name)
        expect(provider).to receive(:get_vm_cpu_architecture).with(pool, vm).and_return(host_architecture)
        expect{ subject._migrate_vm(vm, pool, provider) }.to raise_error(/Unable to determine which host the VM is running on/)
      end
    end

    context 'when VM exists but migration is disabled' do
      before(:each) do
        create_migrating_vm(vm, pool)
        expect(provider).to receive(:get_vm_host).with(pool, vm).and_return(vm_parent_hostname)
        expect(provider).to receive(:get_vm_cluster).with(pool, vm).and_return(cluster_name)
        expect(provider).to receive(:get_vm_cpu_architecture).with(pool, vm).and_return(host_architecture)
      end

      [-1,-32768,false,0].each do |testvalue|
        it "should not migrate a VM if the migration limit is #{testvalue}" do
          config[:config]['migration_limit'] = testvalue
          expect(logger).to receive(:log).with('s', "[ ] [#{pool}] '#{vm}' is running on #{vm_parent_hostname}")
          subject._migrate_vm(vm, pool, provider)
        end

        it "should not remove the VM from vmpooler__migrating queue in redis if the migration limit is #{testvalue}" do
          config[:config]['migration_limit'] = testvalue

          expect(redis.sismember("vmpooler__migrating__#{pool}",vm)).to be_truthy
          subject._migrate_vm(vm, pool, provider)
          expect(redis.sismember("vmpooler__migrating__#{pool}",vm)).to be_falsey
        end
      end
    end

    context 'when VM exists but migration limit is reached' do
      before(:each) do
        expect(provider).to receive(:get_vm_host).with(pool, vm).and_return(vm_parent_hostname)
        expect(provider).to receive(:get_vm_cluster).with(pool, vm).and_return(cluster_name)
        expect(provider).to receive(:get_vm_cpu_architecture).with(pool, vm).and_return(host_architecture)
        #expect(provider).to receive(:select_target_hosts).with(clusters).and_return(provider_hosts)

        create_migrating_vm(vm, pool)
        redis.sadd('vmpooler__migration', 'fakevm1')
        redis.sadd('vmpooler__migration', 'fakevm2')
        redis.sadd('vmpooler__migration', 'fakevm3')
        redis.sadd('vmpooler__migration', 'fakevm4')
        redis.sadd('vmpooler__migration', 'fakevm5')
      end

      it "should not migrate a VM if the migration limit is reached" do
        expect(logger).to receive(:log).with('s',"[ ] [#{pool}] '#{vm}' is running on #{vm_parent_hostname}. No migration will be evaluated since the migration_limit has been reached")
        subject._migrate_vm(vm, pool, provider, provider_hosts)
      end

      it "should remove the VM from vmpooler__migrating queue in redis if the migration limit is reached" do
        expect(redis.sismember("vmpooler__migrating__#{pool}",vm)).to be_truthy
        subject._migrate_vm(vm, pool, provider, provider_hosts)
        expect(redis.sismember("vmpooler__migrating__#{pool}",vm)).to be_falsey
      end
    end

    context 'when VM exists but migration limit is not yet reached' do

      before(:each) do
        create_migrating_vm(vm, pool)
        expect(provider).to receive(:get_vm_host).with(pool, vm).and_return(vm_parent_hostname)
        expect(provider).to receive(:get_vm_cluster).with(pool, vm).and_return(cluster_name)
        expect(provider).to receive(:get_vm_cpu_architecture).with(pool, vm).and_return(host_architecture)
        #expect(provider).to receive(:select_target_hosts).with(clusters).and_return(provider_hosts)
        redis.sadd('vmpooler__migration', 'fakevm1')
        redis.sadd('vmpooler__migration', 'fakevm2')
      end

      context 'and current host is within the list of available targets' do
        let(:target_hosts) { ['host1'] }
        let(:provider_hosts) {
          {
            'check_time_finished' => Time.now,
            'clusters' => {
              'cluster1' => {
                'hosts' => ['host1'],
                'architectures' => { 'v3' => ['host1'] },
                'all_hosts' => ['host1']
              }
            }
          }
        }
        #
        #let(:$provider_hosts) { provider_hosts }
        #let(:target_hosts) { provider_hosts['cluster'][cluster_name]['all_hosts'] }
        before(:each) do
          #expect(provider).to receive(:find_least_used_compatible_host).with(pool, vm).and_return(vm_parent_hostname)
          #expect($provider_hosts['cluster'][cluster_name]['all_hosts']).to receive(:include?).with(parent_host_name).and_return(true)
          #expect(subject).to receive(:host_in_targets?).with(vm_parent_hostname, target_hosts).and_return(true)
        end

        it "should not migrate the VM" do
          expect(provider_hosts['clusters']).to have_key(cluster_name)
          expect(logger).to receive(:log).with('s', "[ ] [#{pool}] No migration required for '#{vm}' running on #{vm_parent_hostname}")
          subject._migrate_vm(vm, pool, provider, provider_hosts)
        end

        it "should remove the VM from vmpooler__migrating queue in redis" do
          expect(redis.sismember("vmpooler__migrating__#{pool}",vm)).to be_truthy
          subject._migrate_vm(vm, pool, provider, provider_hosts)
          expect(redis.sismember("vmpooler__migrating__#{pool}",vm)).to be_falsey
        end

        it "should not change the vmpooler_migration queue count" do
          before_count = redis.scard('vmpooler__migration')
          subject._migrate_vm(vm, pool, provider, provider_hosts)
          expect(redis.scard('vmpooler__migration')).to eq(before_count)
        end

        it "should not call remove_vmpooler_migration_vm" do
          expect(subject).not_to receive(:remove_vmpooler_migration_vm)
          subject._migrate_vm(vm, pool, provider, provider_hosts)
        end
      end

      context 'and host to migrate to different to the current host' do
        let(:vm_new_hostname) { 'host1' }
        let(:vm_parent_hostname) { 'host2' }
        let(:cluster_name) { 'cluster1' }
        let(:dc) { 'dc1' }
        let(:host_architecture) { 'v3' }
        let(:provider_hosts) {
          {
            'check_time_finished' => Time.now,
            'clusters' => {
              'cluster1' => {
                'hosts' => [ 'host1' ],
                'architectures' => { 'v3' => ['host1'] },
                'all_hosts' => ['host1']
              }
            }
          }
        }
        before(:each) do
          #expect(provider).to receive(:get_vm_host).with(pool, vm).and_return(vm_parent_hostname)
          #expect(provider).to receive(:select_hosts).with(provider).and_return(vm_new_hostname)
          expect(subject).to receive(:select_next_host).with(cluster_name, host_architecture, provider_hosts).and_return(provider_hosts['clusters'][cluster_name]['architectures'][host_architecture][0])
          #expect(provider).to receive(:get_vm_cpu_architecture).with(pool, vm).and_return(host_architecture)
          #allow(provider).to receive(:select_target_hosts).with([cluster_name], dc).and_return(provider_hosts)
          expect(subject).to receive(:migrate_vm_and_record_timing).with(vm, pool, vm_parent_hostname, vm_new_hostname, provider).and_return('1.00')
        end

        it "should migrate the VM" do
          expect(logger).to receive(:log).with('s', "[>] [#{pool}] '#{vm}' migrated from #{vm_parent_hostname} to #{vm_new_hostname} in 1.00 seconds")
          subject._migrate_vm(vm, pool, provider, provider_hosts)
        end

        it "should remove the VM from vmpooler__migrating queue in redis" do
          expect(redis.sismember("vmpooler__migrating__#{pool}",vm)).to be_truthy
          subject._migrate_vm(vm, pool, provider, provider_hosts)
          expect(redis.sismember("vmpooler__migrating__#{pool}",vm)).to be_falsey
        end

        it "should not change the vmpooler_migration queue count" do
          before_count = redis.scard('vmpooler__migration')
          subject._migrate_vm(vm, pool, provider, provider_hosts)
          expect(redis.scard('vmpooler__migration')).to eq(before_count)
        end

        it "should call remove_vmpooler_migration_vm" do
          expect(subject).to receive(:remove_vmpooler_migration_vm)
          subject._migrate_vm(vm, pool, provider, provider_hosts)
        end
      end
    end
  end

  describe "#execute!" do
    let(:config) {
      YAML.load(<<-EOT
---
:pools:
  - name: #{pool}
EOT
      )
    }

    before(:each) do
      expect(subject).not_to be_nil

      allow(subject).to receive(:check_disk_queue)
      allow(subject).to receive(:check_snapshot_queue)
      allow(subject).to receive(:check_pool)

      allow(logger).to receive(:log)
    end

    after(:each) do
      # Reset the global variable - Note this is a code smell
      $threads = nil
    end

    context 'on startup' do
      it 'should log a message that VMPooler has started' do
        expect(logger).to receive(:log).with('d', 'starting vmpooler')

        subject.execute!(1,0)
      end

      it 'should set clone tasks to zero' do
        redis.set('vmpooler__tasks__clone', 1)
        subject.execute!(1,0)
        expect(redis.get('vmpooler__tasks__clone')).to eq('0')
      end

      it 'should clear migration tasks' do
        redis.set('vmpooler__migration', 1)
        subject.execute!(1,0)
        expect(redis.get('vmpooler__migration')).to be_nil
      end

      it 'should run the check_disk_queue method' do
        expect(subject).to receive(:check_disk_queue)

        subject.execute!(1,0)
      end

      it 'should run the check_snapshot_queue method' do
        expect(subject).to receive(:check_snapshot_queue)

        subject.execute!(1,0)
      end

      it 'should check the pools in the config' do
        expect(subject).to receive(:check_pool).with(a_pool_with_name_of(pool))

        subject.execute!(1,0)
      end

      context 'creating Providers' do
        let(:vsphere_provider) { double('vsphere_provider') }
        let(:config) {
        YAML.load(<<-EOT
---
:pools:
  - name: #{pool}
  - name: 'dummy'
    provider: 'vsphere'
EOT
        )}

        it 'should call create_provider_object idempotently' do
          # Even though there are two pools using the vsphere provider (the default), it should only
          # create the provider object once.
          expect(subject).to receive(:create_provider_object).with(Object, Object, Object, 'vsphere', 'vsphere', Object).and_return(vsphere_provider)

          subject.execute!(1,0)
        end

        it 'should raise an error if the provider can not be created' do
          expect(subject).to receive(:create_provider_object).and_raise(RuntimeError, "MockError")

          expect{ subject.execute!(1,0) }.to raise_error(/MockError/)
        end

        it 'should log a message if the provider can not be created' do
          expect(subject).to receive(:create_provider_object).and_raise(RuntimeError, "MockError")
          expect(logger).to receive(:log).with('s',"Error while creating provider for pool #{pool}: MockError")

          expect{ subject.execute!(1,0) }.to raise_error(/MockError/)
        end
      end
    end

    context 'creating multiple vsphere Providers' do
      let(:vsphere_provider) { double('vsphere_provider') }
      let(:vsphere_provider2) { double('vsphere_provider') }
      let(:provider1) { Vmpooler::PoolManager::Provider::Base.new(config, logger, metrics, 'vsphere', provider_options) }
      let(:provider2) { Vmpooler::PoolManager::Provider::Base.new(config, logger, metrics, 'secondvsphere', provider_options) }
      let(:config) {
        YAML.load(<<-EOT
---
:providers:
  :vsphere:
    server: 'blah1'
    provider_class: 'vsphere'
  :secondvsphere:
    server: 'blah2'
    provider_class: 'vsphere'
:pools:
  - name: #{pool}
    provider: 'vsphere'
  - name: 'secondpool'
    provider: 'secondvsphere'
EOT
        )}

      it 'should call create_provider_object twice' do
        # The two pools use a different provider name, but each provider_class is vsphere
        expect(subject).to receive(:create_provider_object).with(Object, Object, Object, "vsphere", "vsphere", Object).and_return(vsphere_provider)
        expect(subject).to receive(:create_provider_object).with(Object, Object, Object, "vsphere", "secondvsphere", Object).and_return(vsphere_provider2)
        subject.execute!(1,0)
      end

      it 'should have vsphere providers with different servers' do
        allow(subject).to receive(:get_provider_for_pool).with(pool).and_return(provider1)
        result = subject.get_provider_for_pool(pool)
        allow(provider1).to receive(:provider_config).and_call_original
        expect(result.provider_config['server']).to eq('blah1')

        allow(subject).to receive(:get_provider_for_pool).with('secondpool').and_return(provider2)
        result = subject.get_provider_for_pool('secondpool')
        allow(provider1).to receive(:provider_config).and_call_original
        expect(result.provider_config['server']).to eq('blah2')
        subject.execute!(1,0)
      end
    end

    context 'modify configuration on startup' do
      context 'move vSphere configuration to providers location' do
        let(:config) {
        YAML.load(<<-EOT
:vsphere:
  server: 'vsphere.company.com'
  username: 'vmpooler'
  password: 'password'
:pools:
  - name: #{pool}
EOT
        )}

        it 'should set providers with no provider to vsphere' do
          expect(subject.config[:providers]).to be nil

          subject.execute!(1,0)
          expect(subject.config[:providers][:vsphere]['server']).to eq('vsphere.company.com')
          expect(subject.config[:providers][:vsphere]['username']).to eq('vmpooler')
          expect(subject.config[:providers][:vsphere]['password']).to eq('password')
        end

        it 'should log a message' do
          expect(logger).to receive(:log).with('d', "[!] Detected an older configuration file. Copying the settings from ':vsphere:' to ':providers:/:vsphere:'")

          subject.execute!(1,0)
        end
      end


      context 'default to the vphere provider' do
        let(:config) {
        YAML.load(<<-EOT
---
:pools:
  - name: #{pool}
  - name: 'dummy'
    provider: 'dummy'
EOT
        )}

        it 'should set providers with no provider to vsphere' do
          expect(subject.config[:pools][0]['provider']).to be_nil
          expect(subject.config[:pools][1]['provider']).to eq('dummy')

          subject.execute!(1,0)

          expect(subject.config[:pools][0]['provider']).to eq('vsphere')
          expect(subject.config[:pools][1]['provider']).to eq('dummy')
        end

        it 'should log a message' do
          expect(logger).to receive(:log).with('d', "[!] Setting provider for pool '#{pool}' to 'vsphere' as default")

          subject.execute!(1,0)
        end
      end
    end

    context 'with dead disk_manager thread' do
      let(:disk_manager_thread) { double('thread', :alive? => false) }

      before(:each) do
        # Reset the global variable - Note this is a code smell
        $threads = {}
        $threads['disk_manager'] = disk_manager_thread
      end

      it 'should run the check_disk_queue method and log a message' do
        expect(subject).to receive(:check_disk_queue)
        expect(logger).to receive(:log).with('d', "[!] [disk_manager] worker thread died, restarting")

        subject.execute!(1,0)
      end
    end

    context 'with dead snapshot_manager thread' do
      let(:snapshot_manager_thread) { double('thread', :alive? => false) }
      before(:each) do
        # Reset the global variable - Note this is a code smell
        $threads = {}
        $threads['snapshot_manager'] = snapshot_manager_thread
      end

      it 'should run the check_snapshot_queue method and log a message' do
        expect(subject).to receive(:check_snapshot_queue)
        expect(logger).to receive(:log).with('d', "[!] [snapshot_manager] worker thread died, restarting")
        $threads['snapshot_manager'] = snapshot_manager_thread

        subject.execute!(1,0)
      end
    end

    context 'with dead pool thread' do
      context 'without check_loop_delay_xxx settings' do
        let(:pool_thread) { double('thread', :alive? => false) }
        let(:default_check_loop_delay_min) { 5 }
        let(:default_check_loop_delay_max) { 60 }
        let(:default_check_loop_delay_decay) { 2.0 }
        before(:each) do
          # Reset the global variable - Note this is a code smell
          $threads = {}
          $threads[pool] = pool_thread
        end

        it 'should run the check_pool method and log a message' do
          expect(subject).to receive(:check_pool).with(a_pool_with_name_of(pool),
                                                       default_check_loop_delay_min,
                                                       default_check_loop_delay_max,
                                                       default_check_loop_delay_decay)
          expect(logger).to receive(:log).with('d', "[!] [#{pool}] worker thread died, restarting")

          subject.execute!(1,0)
        end
      end

      context 'with check_loop_delay_xxx settings' do
        let(:pool_thread) { double('thread', :alive? => false) }
        let(:check_loop_delay_min) { 7 }
        let(:check_loop_delay_max) { 20 }
        let(:check_loop_delay_decay) { 2.1 }

        let(:config) {
      YAML.load(<<-EOT
---
:config:
  check_loop_delay_min: #{check_loop_delay_min}
  check_loop_delay_max: #{check_loop_delay_max}
  check_loop_delay_decay: #{check_loop_delay_decay}
:pools:
  - name: #{pool}
EOT
          )
        }
        before(:each) do
          # Reset the global variable - Note this is a code smell
          $threads = {}
          $threads[pool] = pool_thread
        end

        it 'should run the check_pool method and log a message' do
          expect(subject).to receive(:check_pool).with(a_pool_with_name_of(pool),
                                                       check_loop_delay_min,
                                                       check_loop_delay_max,
                                                       check_loop_delay_decay)
          expect(logger).to receive(:log).with('d', "[!] [#{pool}] worker thread died, restarting")

          subject.execute!(1,0)
        end
      end
    end

    context 'delays between loops' do
      let(:maxloop) { 2 }
      let(:loop_delay) { 1 }
      # Note a maxloop of zero can not be tested as it never terminates
      before(:each) do
  
        allow(subject).to receive(:check_disk_queue)
        allow(subject).to receive(:check_snapshot_queue)
        allow(subject).to receive(:check_pool)
      end

      it 'when a non-default loop delay is specified' do
        expect(subject).to receive(:sleep).with(loop_delay).exactly(maxloop).times

        subject.execute!(maxloop,loop_delay)
      end
    end

    context 'loops specified number of times (5)' do
      let(:alive_thread) { double('thread', :alive? => true) }
      let(:maxloop) { 5 }
      # Note a maxloop of zero can not be tested as it never terminates
      before(:each) do
        end

      it 'should run startup tasks only once' do
        expect(redis).to receive(:set).with('vmpooler__tasks__clone', 0).once
        expect(redis).to receive(:del).with('vmpooler__migration').once

        subject.execute!(maxloop,0)
      end

      it 'should run per thread tasks 5 times when threads are not remembered' do
        expect(subject).to receive(:check_disk_queue).exactly(maxloop).times
        expect(subject).to receive(:check_snapshot_queue).exactly(maxloop).times
        expect(subject).to receive(:check_pool).exactly(maxloop).times

        subject.execute!(maxloop,0)
      end

      it 'should not run per thread tasks when threads are alive' do
        expect(subject).to receive(:check_disk_queue).exactly(0).times
        expect(subject).to receive(:check_snapshot_queue).exactly(0).times
        expect(subject).to receive(:check_pool).exactly(0).times

        $threads[pool] = alive_thread
        $threads['disk_manager'] = alive_thread
        $threads['snapshot_manager'] = alive_thread

        subject.execute!(maxloop,0)
      end
    end
  end

  describe "#sleep_with_wakeup_events" do
    let(:loop_delay) { 10 }
    before(:each) do
      allow(Kernel).to receive(:sleep).and_raise("sleep should not be called")
      allow(subject).to receive(:time_passed?).with(:wakeup_by, Time).and_call_original
      allow(subject).to receive(:time_passed?).with(:exit_by, Time).and_call_original
    end

    it 'should not sleep if the loop delay is negative' do
      expect(subject).to receive(:sleep).exactly(0).times

      subject.sleep_with_wakeup_events(-1)
    end

    it 'should sleep until the loop delay is exceeded' do
      # This test is a little brittle as it requires knowledge of the implementation
      # Basically the number of sleep delays will dictate how often the time_passed? method is called

      expect(subject).to receive(:sleep).exactly(2).times
      expect(subject).to receive(:time_passed?).with(:exit_by, Time).and_return(false, false, false, true)
      
      subject.sleep_with_wakeup_events(loop_delay)
    end

    describe 'with the pool_size_change wakeup option' do
      let(:wakeup_option) {{
        :pool_size_change => true,
        :poolname => pool,
      }}
      let(:wakeup_period) { -1 } # A negative number forces the wakeup evaluation to always occur

      it 'should check the number of VMs ready in Redis' do
        expect(subject).to receive(:time_passed?).with(:exit_by, Time).and_return(false, true)
        expect(redis).to receive(:scard).with("vmpooler__ready__#{pool}").once

        subject.sleep_with_wakeup_events(loop_delay, wakeup_period, wakeup_option)
      end

      it 'should sleep until the number of VMs ready in Redis increases' do
        expect(subject).to receive(:sleep).exactly(3).times
        expect(redis).to receive(:scard).with("vmpooler__ready__#{pool}").and_return(1,1,1,2)

        subject.sleep_with_wakeup_events(loop_delay, wakeup_period, wakeup_option)
      end

      it 'should sleep until the number of VMs ready in Redis decreases' do
        expect(subject).to receive(:sleep).exactly(3).times
        expect(redis).to receive(:scard).with("vmpooler__ready__#{pool}").and_return(2,2,2,1)

        subject.sleep_with_wakeup_events(loop_delay, wakeup_period, wakeup_option)
      end
    end
  end
  
  describe "#check_pool" do
    let(:threads) {{}}
    let(:provider_name) { 'mock_provider' }
    let(:config) {
      YAML.load(<<-EOT
---
:pools:
  - name: #{pool}
    provider: #{provider_name}
EOT
      )
    }

    let(:pool_object) { config[:pools][0] }
    let(:check_pool_response) {{
        :discovered_vms      => 0,
        :checked_running_vms => 0,
        :checked_ready_vms   => 0,
        :checked_pending_vms => 0,
        :destroyed_vms       => 0,
        :migrated_vms        => 0,
        :cloned_vms          => 0,
    }}

    before do
      expect(subject).not_to be_nil
      expect(Thread).to receive(:new).and_yield
      allow(subject).to receive(:get_provider_for_pool).with(pool).and_return(provider)
    end

    context 'on startup' do
      before(:each) do
        allow(subject).to receive(:_check_pool).and_return(check_pool_response)
        expect(logger).to receive(:log).with('d', "[*] [#{pool}] starting worker thread")
      end

      after(:each) do
        # Reset the global variable - Note this is a code smell
        $threads = nil
      end

      it 'should log a message the worker thread is starting' do
        subject.check_pool(pool_object,1,0)
      end

      it 'should populate the threads global variable' do
        subject.check_pool(pool_object,1,0)

        # Unable to test for nil as the Thread is mocked
        expect($threads.keys.include?(pool))
      end
    end

    context 'delays between loops' do
      let(:maxloop) { 2 }
      let(:loop_delay) { 1 }
      # Note a maxloop of zero can not be tested as it never terminates

      before(:each) do
        allow(logger).to receive(:log)
        allow(subject).to receive(:_check_pool).and_return(check_pool_response)
      end

      after(:each) do
        # Reset the global variable - Note this is a code smell
        $threads = nil
      end

      it 'when a non-default loop delay is specified' do
        expect(subject).to receive(:sleep_with_wakeup_events).with(loop_delay, Numeric, Hash).exactly(maxloop).times

        subject.check_pool(pool_object,maxloop,loop_delay,loop_delay)
      end

      it 'specifies a wakeup option for pool size change' do
        expect(subject).to receive(:sleep_with_wakeup_events).with(loop_delay, Numeric, hash_including(:pool_size_change => true)).exactly(maxloop).times

        subject.check_pool(pool_object,maxloop,loop_delay,loop_delay)
      end

      it 'specifies a wakeup option for poolname' do
        expect(subject).to receive(:sleep_with_wakeup_events).with(loop_delay, Numeric, hash_including(:poolname => pool)).exactly(maxloop).times

        subject.check_pool(pool_object,maxloop,loop_delay,loop_delay)
      end
    end

    context 'delays between loops configured in the pool configuration' do
      let(:maxloop) { 2 }
      let(:loop_delay) { 1 }
      let(:pool_loop_delay) { 2 }
      let(:config) {
        YAML.load(<<-EOT
---
:pools:
  - name: #{pool}
    provider: #{provider_name}
    check_loop_delay_min: #{pool_loop_delay}
    check_loop_delay_max: #{pool_loop_delay}
EOT
        )
      }

      before(:each) do
        allow(logger).to receive(:log)
        allow(subject).to receive(:_check_pool).and_return(check_pool_response)
      end

      after(:each) do
        # Reset the global variable - Note this is a code smell
        $threads = nil
      end

      it 'when a non-default loop delay is specified' do
        expect(subject).to receive(:sleep_with_wakeup_events).with(pool_loop_delay, pool_loop_delay, Hash).exactly(maxloop).times

        subject.check_pool(pool_object,maxloop,loop_delay)
      end
    end

    context 'delays between loops with a specified min and max value' do
      let(:maxloop) { 5 }
      let(:loop_delay_min) { 1 }
      let(:loop_delay_max) { 60 }
      # Note a maxloop of zero can not be tested as it never terminates

      before(:each) do
        allow(logger).to receive(:log)
        allow(subject).to receive(:_check_pool).and_return(check_pool_response)
      end

      after(:each) do
        # Reset the global variable - Note this is a code smell
        $threads = nil
      end

      [:checked_pending_vms, :discovered_vms, :cloned_vms].each do |testcase|
        describe "when #{testcase} is greater than zero" do
          it "delays the minimum delay time" do
            expect(subject).to receive(:sleep_with_wakeup_events).with(loop_delay_min, loop_delay_min, Hash).exactly(maxloop).times
            check_pool_response[testcase] = 1

            subject.check_pool(pool_object,maxloop,loop_delay_min,loop_delay_max)
          end
        end
      end

      [:checked_running_vms, :checked_ready_vms, :destroyed_vms, :migrated_vms].each do |testcase|
        describe "when #{testcase} is greater than zero" do
          let(:loop_decay) { 3.0 }
          it "delays increases with a decay" do
            expect(subject).to receive(:sleep_with_wakeup_events).with(3, Numeric, Hash).once
            expect(subject).to receive(:sleep_with_wakeup_events).with(9, Numeric, Hash).once
            expect(subject).to receive(:sleep_with_wakeup_events).with(27, Numeric, Hash).once
            expect(subject).to receive(:sleep_with_wakeup_events).with(60, Numeric, Hash).twice
            check_pool_response[testcase] = 1

            subject.check_pool(pool_object,maxloop,loop_delay_min,loop_delay_max,loop_decay)
          end
        end
      end
    end

    context 'delays between loops with a specified min and max value configured in the pool configuration' do
      let(:maxloop) { 5 }
      let(:loop_delay_min) { 1 }
      let(:loop_delay_max) { 60 }
      let(:loop_decay) { 3.0 }
      let(:pool_loop_delay_min) { 3 }
      let(:pool_loop_delay_max) { 70 }
      let(:pool_loop_delay_decay) { 2.5 }
      let(:config) {
        YAML.load(<<-EOT
---
:pools:
  - name: #{pool}
    provider: #{provider_name}
    check_loop_delay_min: #{pool_loop_delay_min}
    check_loop_delay_max: #{pool_loop_delay_max}
    check_loop_delay_decay: #{pool_loop_delay_decay}
EOT
        )
      }

      before(:each) do
        allow(logger).to receive(:log)
        allow(subject).to receive(:_check_pool).and_return(check_pool_response)
      end

      after(:each) do
        # Reset the global variable - Note this is a code smell
        $threads = nil
      end

      [:checked_pending_vms, :discovered_vms, :cloned_vms].each do |testcase|
        describe "when #{testcase} is greater than zero" do
          it "delays the minimum delay time" do
            expect(subject).to receive(:sleep_with_wakeup_events).with(pool_loop_delay_min, Numeric, Hash).exactly(maxloop).times
            check_pool_response[testcase] = 1

            subject.check_pool(pool_object,maxloop,loop_delay_min,loop_delay_max,loop_decay)
          end
        end
      end

      [:checked_running_vms, :checked_ready_vms, :destroyed_vms, :migrated_vms].each do |testcase|
        describe "when #{testcase} is greater than zero" do
          it "delays increases with a decay" do
            expect(subject).to receive(:sleep_with_wakeup_events).with(7, Numeric, Hash).once
            expect(subject).to receive(:sleep_with_wakeup_events).with(17, Numeric, Hash).once
            expect(subject).to receive(:sleep_with_wakeup_events).with(42, Numeric, Hash).once
            expect(subject).to receive(:sleep_with_wakeup_events).with(70, Numeric, Hash).twice
            check_pool_response[testcase] = 1

            subject.check_pool(pool_object,maxloop,loop_delay_min,loop_delay_max,loop_decay)
          end
        end
      end
    end


    context 'loops specified number of times (5)' do
      let(:maxloop) { 5 }
      # Note a maxloop of zero can not be tested as it never terminates
      before(:each) do
        allow(logger).to receive(:log)
        allow(subject).to receive(:_check_pool).and_return(check_pool_response)
      end

      after(:each) do
        # Reset the global variable - Note this is a code smell
        $threads = nil
        $provider = nil
      end

      it 'should run startup tasks only once' do
        expect(logger).to receive(:log).with('d', "[*] [#{pool}] starting worker thread")

        subject.check_pool(pool_object,maxloop,0)
      end

      it 'should run per thread tasks 5 times' do
        expect(subject).to receive(:_check_pool).exactly(maxloop).times

        subject.check_pool(pool_object,maxloop,0)
      end
    end
  end

  describe '#remove_vmpooler_migration_vm' do
    before do
      expect(subject).not_to be_nil
    end

    it 'should remove the migration from redis' do
      redis.sadd('vmpooler__migration', vm)
      expect(redis.sismember('vmpooler__migration',vm)).to be(true)
      subject.remove_vmpooler_migration_vm(pool, vm)
      expect(redis.sismember('vmpooler__migration',vm)).to be(false)
    end

    it 'should log a message and swallow an error if one occurs' do
      expect(redis).to receive(:srem).and_raise(RuntimeError,'MockError')
      expect(logger).to receive(:log).with('s', "[x] [#{pool}] '#{vm}' removal from vmpooler__migration failed with an error: MockError")
      subject.remove_vmpooler_migration_vm(pool, vm)
    end
  end

  describe '#migrate_vm_and_record_timing' do
    let(:source_host_name) { 'source_host' }
    let(:dest_host_name) { 'dest_host' }

    before(:each) do
      create_vm(vm,token)
      expect(subject).not_to be_nil

      expect(provider).to receive(:migrate_vm_to_host).with(pool, vm, dest_host_name)
    end

    it 'should return the elapsed time for the migration' do
      result = subject.migrate_vm_and_record_timing(vm, pool, source_host_name, dest_host_name, provider)
      expect(result).to match(/0\.[\d]+/)
    end

    it 'should add timing metric' do
      expect(metrics).to receive(:timing).with("migrate.#{pool}",String)
      subject.migrate_vm_and_record_timing(vm, pool, source_host_name, dest_host_name, provider)
    end

    it 'should increment from_host and to_host metric' do
      expect(metrics).to receive(:increment).with("migrate_from.#{source_host_name}")
      expect(metrics).to receive(:increment).with("migrate_to.#{dest_host_name}")
      subject.migrate_vm_and_record_timing(vm, pool, source_host_name, dest_host_name, provider)
    end

    it 'should set migration_time metric in redis' do
      expect(redis.hget("vmpooler__vm__#{vm}", 'migration_time')).to be_nil
      subject.migrate_vm_and_record_timing(vm, pool, source_host_name, dest_host_name, provider)
      expect(redis.hget("vmpooler__vm__#{vm}", 'migration_time')).to match(/0\.[\d]+/)
    end

    it 'should set checkout_to_migration metric in redis' do
      expect(redis.hget("vmpooler__vm__#{vm}", 'checkout_to_migration')).to be_nil
      subject.migrate_vm_and_record_timing(vm, pool, source_host_name, dest_host_name, provider)
      expect(redis.hget("vmpooler__vm__#{vm}", 'checkout_to_migration')).to match(/[01]\.[\d]+/)
    end
  end

  describe '#_check_pool' do
    let(:new_vm_response) {
      # Mock response from Base Provider for vms_in_pool
      [{ 'name' => new_vm}]
    }
    let(:vm_response) {
      # Mock response from Base Provider for vms_in_pool
      [{ 'name' => vm}]
    }
    let(:multi_vm_response) {
      # Mock response from Base Provider for vms_in_pool
      [{ 'name' => 'vm1'},
       { 'name' => 'vm2'},
       { 'name' => 'vm3'}]
    }

    # Default test fixtures will consist of;
    #   - Empty Redis dataset
    #   - A single pool with a pool size of zero i.e. no new VMs should be created
    #   - Task limit of 10
    let(:config) {
      YAML.load(<<-EOT
---
:config:
  task_limit: 10
:pools:
  - name: #{pool}
    size: 10
EOT
      )
    }
    let(:pool_object) { config[:pools][0] }
    let(:new_vm) { 'newvm'}
    let(:pool_name) { pool_object['name'] }

    before do
      expect(subject).not_to be_nil
      allow(logger).to receive(:log)
    end

    # INVENTORY
    context 'Conducting inventory' do
      before(:each) do
        allow(subject).to receive(:migrate_vm)
        allow(subject).to receive(:check_running_vm)
        allow(subject).to receive(:check_ready_vm)
        allow(subject).to receive(:check_pending_vm)
        allow(subject).to receive(:destroy_vm)
        allow(subject).to receive(:clone_vm)
        allow(provider).to receive(:vms_in_pool).with(pool).and_return(new_vm_response)
      end

      it 'should log an error if one occurs' do
        expect(provider).to receive(:vms_in_pool).and_raise(RuntimeError,'Mock Error')
        expect(logger).to receive(:log).with('s', "[!] [#{pool}] _check_pool failed with an error while inspecting inventory: Mock Error")

        subject._check_pool(pool_object,provider)
      end

      it 'should not perform any other actions if an error occurs' do
        # Add VMs into redis
        create_running_vm(pool_name, 'vm1')
        create_ready_vm(pool_name, 'vm2')
        create_completed_vm('vm3', pool_name)
        create_discovered_vm('vm4', pool_name)
        create_migrating_vm('vm5', pool_name)

        expect(subject).to receive(:move_vm_queue).exactly(0).times
        expect(subject).to receive(:check_running_vm).exactly(0).times
        expect(subject).to receive(:check_pending_vm).exactly(0).times
        expect(subject).to receive(:destroy_vm).exactly(0).times
        expect(redis).to receive(:srem).exactly(0).times
        expect(redis).to receive(:del).exactly(0).times
        expect(redis).to receive(:hdel).exactly(0).times
        expect(redis).to receive(:smove).exactly(0).times
        expect(subject).to receive(:migrate_vm).exactly(0).times
        expect(redis).to receive(:set).exactly(0).times
        expect(redis).to receive(:incr).exactly(0).times
        expect(subject).to receive(:clone_vm).exactly(0).times
        expect(redis).to receive(:decr).exactly(0).times

        expect(provider).to receive(:vms_in_pool).and_raise(RuntimeError,'Mock Error')
        subject._check_pool(pool_object,provider)
      end

      it 'should return that no actions were taken' do
        expect(provider).to receive(:vms_in_pool).and_raise(RuntimeError,'Mock Error')

        result = subject._check_pool(pool_object,provider)

        expect(result[:discovered_vms]).to be(0)
        expect(result[:checked_running_vms]).to be(0)
        expect(result[:checked_ready_vms]).to be(0)
        expect(result[:checked_pending_vms]).to be(0)
        expect(result[:destroyed_vms]).to be(0)
        expect(result[:migrated_vms]).to be(0)
        expect(result[:cloned_vms]).to be(0)
      end

      it 'should log the discovery of VMs' do
        expect(logger).to receive(:log).with('s', "[?] [#{pool}] '#{new_vm}' added to 'discovered' queue")

        subject._check_pool(pool_object,provider)
      end

      it 'should return the number of discovered VMs' do
        result = subject._check_pool(pool_object,provider)

        expect(result[:discovered_vms]).to be(1)
      end

      it 'should add undiscovered VMs to the completed queue' do
        allow(logger).to receive(:log).with('s', "[?] [#{pool}] '#{new_vm}' added to 'discovered' queue")

        expect(redis.sismember("vmpooler__discovered__#{pool}", new_vm)).to be(false)
        expect(redis.sismember("vmpooler__completed__#{pool}", new_vm)).to be(false)

        subject._check_pool(pool_object,provider)

        expect(redis.sismember("vmpooler__discovered__#{pool}", new_vm)).to be(false)
        expect(redis.sismember("vmpooler__completed__#{pool}", new_vm)).to be(true)
      end

      ['running','ready','pending','completed','discovered','migrating'].each do |queue_name|
        it "should not discover VMs in the #{queue_name} queue" do
          expect(logger).to receive(:log).with('s', "[?] [#{pool}] '#{new_vm}' added to 'discovered' queue").exactly(0).times
          expect(redis.sismember("vmpooler__discovered__#{pool}", new_vm)).to be(false)
          redis.sadd("vmpooler__#{queue_name}__#{pool}", new_vm)

          subject._check_pool(pool_object,provider)

          if queue_name == 'discovered'
            # Discovered VMs end up in the completed queue
            expect(redis.sismember("vmpooler__completed__#{pool}", new_vm)).to be(true)
          else
            expect(redis.sismember("vmpooler__#{queue_name}__#{pool}", new_vm)).to be(true)
          end
        end
      end
    end

    # RUNNING
    context 'Running VM not in the inventory' do
      before(:each) do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return(new_vm_response)
        expect(logger).to receive(:log).with('s', "[?] [#{pool}] '#{new_vm}' added to 'discovered' queue")
        create_running_vm(pool,vm,token)
      end

      it 'should not call check_running_vm' do
        expect(subject).to receive(:check_running_vm).exactly(0).times

        subject._check_pool(pool_object,provider)
      end

      it 'should move the VM to completed queue' do
        expect(subject).to receive(:move_vm_queue).with(pool,vm,'running','completed',String).and_call_original

        subject._check_pool(pool_object,provider)
      end
    end

    context 'Running VM in the inventory' do
      before(:each) do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return(vm_response)
        allow(subject).to receive(:check_running_vm)
        create_running_vm(pool,vm,token)
      end

      it 'should log an error if one occurs' do
        expect(subject).to receive(:check_running_vm).and_raise(RuntimeError,'MockError')
        expect(logger).to receive(:log).with('d', "[!] [#{pool}] _check_pool with an error while evaluating running VMs: MockError")

        subject._check_pool(pool_object,provider)
      end

      it 'should return the number of checked running VMs' do
        result = subject._check_pool(pool_object,provider)

        expect(result[:checked_running_vms]).to be(1)
      end

      it 'should use the VM lifetime in preference to defaults' do
        big_lifetime = 2000

        redis.hset("vmpooler__vm__#{vm}", 'lifetime',big_lifetime)
        # The lifetime comes in as string
        expect(subject).to receive(:check_running_vm).with(vm,pool,"#{big_lifetime}",provider)

        subject._check_pool(pool_object,provider)
      end

      it 'should use the configuration default if the VM lifetime is not set' do
        config[:config]['vm_lifetime'] = 50
        expect(subject).to receive(:check_running_vm).with(vm,pool,50,provider)

        subject._check_pool(pool_object,provider)
      end

      it 'should use a lifetime of 12 if nothing is set' do
        expect(subject).to receive(:check_running_vm).with(vm,pool,12,provider)

        subject._check_pool(pool_object,provider)
      end
    end

    # READY
    context 'Ready VM not in the inventory' do
      before(:each) do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return(new_vm_response)
        expect(logger).to receive(:log).with('s', "[?] [#{pool}] '#{new_vm}' added to 'discovered' queue")
        create_ready_vm(pool,vm,token)
      end

      it 'should not call check_ready_vm' do
        expect(subject).to receive(:check_ready_vm).exactly(0).times

        subject._check_pool(pool_object,provider)
      end

      it 'should move the VM to completed queue' do
        expect(subject).to receive(:move_vm_queue).with(pool,vm,'ready','completed',String).and_call_original

        subject._check_pool(pool_object,provider)
      end
    end

    context 'Ready VM in the inventory' do
      before(:each) do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return(vm_response)
        allow(subject).to receive(:check_ready_vm)
        create_ready_vm(pool,vm,token)
      end

      it 'should return the number of checked ready VMs' do
        result = subject._check_pool(pool_object,provider)

        expect(result[:checked_ready_vms]).to be(1)
      end

      it 'should log an error if one occurs' do
        expect(subject).to receive(:check_ready_vm).and_raise(RuntimeError,'MockError')
        expect(logger).to receive(:log).with('d', "[!] [#{pool}] _check_pool failed with an error while evaluating ready VMs: MockError")

        subject._check_pool(pool_object,provider)
      end

      it 'should use the pool TTL if set' do
        big_lifetime = 2000

        config[:pools][0]['ready_ttl'] = big_lifetime
        expect(subject).to receive(:check_ready_vm).with(vm,pool,big_lifetime,provider)

        subject._check_pool(pool_object,provider)
      end

      it 'should use a pool TTL of zero if none set' do
        expect(subject).to receive(:check_ready_vm).with(vm,pool,0,provider)

        subject._check_pool(pool_object,provider)
      end
    end

    # PENDING
    context 'Pending VM not in the inventory' do
      before(:each) do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return(new_vm_response)
        expect(logger).to receive(:log).with('s', "[?] [#{pool}] '#{new_vm}' added to 'discovered' queue")
        create_pending_vm(pool,vm,token)
      end

      it 'should call fail_pending_vm' do
        expect(subject).to receive(:check_ready_vm).exactly(0).times
        expect(subject).to receive(:fail_pending_vm).with(vm,pool,Integer,false)

        subject._check_pool(pool_object,provider)
      end
    end

    context 'Pending VM in the inventory' do
      before(:each) do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return(vm_response)
        allow(subject).to receive(:check_pending_vm)
        create_pending_vm(pool,vm,token)
      end

      it 'should return the number of checked pending VMs' do
        result = subject._check_pool(pool_object,provider)

        expect(result[:checked_pending_vms]).to be(1)
      end

      it 'should log an error if one occurs' do
        expect(subject).to receive(:check_pending_vm).and_raise(RuntimeError,'MockError')
        expect(logger).to receive(:log).with('d', "[!] [#{pool}] _check_pool failed with an error while evaluating pending VMs: MockError")

        subject._check_pool(pool_object,provider)
      end

      it 'should use the pool timeout if set' do
        big_lifetime = 2000

        config[:pools][0]['timeout'] = big_lifetime
        expect(subject).to receive(:check_pending_vm).with(vm,pool,big_lifetime,provider)

        subject._check_pool(pool_object,provider)
      end

      it 'should use the configuration setting if the pool timeout is not set' do
        big_lifetime = 2000

        config[:config]['timeout'] = big_lifetime
        expect(subject).to receive(:check_pending_vm).with(vm,pool,big_lifetime,provider)

        subject._check_pool(pool_object,provider)
      end

      it 'should use a pool timeout of 15 if nothing is set' do
        expect(subject).to receive(:check_pending_vm).with(vm,pool,15,provider)

        subject._check_pool(pool_object,provider)
      end
    end

    # COMPLETED
    context 'Completed VM not in the inventory' do
      before(:each) do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return(new_vm_response)
        expect(logger).to receive(:log).with('s', "[?] [#{pool}] '#{new_vm}' added to 'discovered' queue")
        expect(logger).to receive(:log).with('s', "[!] [#{pool}] '#{vm}' not found in inventory, removed from 'completed' queue")
        create_completed_vm(vm,pool,true)
      end

      it 'should log a message' do
        subject._check_pool(pool_object,provider)
      end

      it 'should not call destroy_vm' do
        expect(subject).to receive(:destroy_vm).exactly(0).times

        subject._check_pool(pool_object,provider)
      end

      it 'should remove redis information' do
        expect(redis.sismember("vmpooler__completed__#{pool}",vm)).to be(true)
        expect(redis.hget("vmpooler__vm__#{vm}", 'checkout')).to_not be(nil)
        expect(redis.hget("vmpooler__active__#{pool}",vm)).to_not be(nil)

        subject._check_pool(pool_object,provider)

        expect(redis.sismember("vmpooler__completed__#{pool}",vm)).to be(false)
        expect(redis.hget("vmpooler__vm__#{vm}", 'checkout')).to be(nil)
        expect(redis.hget("vmpooler__active__#{pool}",vm)).to be(nil)
      end
    end

    context 'Completed VM in the inventory' do
      before(:each) do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return(vm_response)
        create_completed_vm(vm,pool,true)
      end

      it 'should call destroy_vm' do
        expect(subject).to receive(:destroy_vm)

        subject._check_pool(pool_object,provider)
      end

      it 'should return the number of destroyed VMs' do
        result = subject._check_pool(pool_object,provider)

        expect(result[:destroyed_vms]).to be(1)
      end

      context 'with an error during destroy_vm' do
        before(:each) do
          expect(subject).to receive(:destroy_vm).and_raise(RuntimeError,"MockError")
          expect(logger).to receive(:log).with('d', "[!] [#{pool}] _check_pool failed with an error while evaluating completed VMs: MockError")
        end

        it 'should log a message' do
          subject._check_pool(pool_object,provider)
        end

        it 'should remove redis information' do
          expect(redis.sismember("vmpooler__completed__#{pool}",vm)).to be(true)
          expect(redis.hget("vmpooler__vm__#{vm}", 'checkout')).to_not be(nil)
          expect(redis.hget("vmpooler__active__#{pool}",vm)).to_not be(nil)

          subject._check_pool(pool_object,provider)

          expect(redis.sismember("vmpooler__completed__#{pool}",vm)).to be(false)
          expect(redis.hget("vmpooler__vm__#{vm}", 'checkout')).to be(nil)
          expect(redis.hget("vmpooler__active__#{pool}",vm)).to be(nil)
        end
      end
    end

    # DISCOVERED
    context 'Discovered VM' do
      before(:each) do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return(vm_response)
        create_discovered_vm(vm,pool)
      end

      it 'should be moved to the completed queue' do
        subject._check_pool(pool_object,provider)

        expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(true)
      end

      it 'should log a message if an error occurs' do
        expect(redis).to receive(:smove).with("vmpooler__discovered__#{pool}", "vmpooler__completed__#{pool}", vm).and_raise(RuntimeError,'MockError')
        expect(logger).to receive(:log).with("d", "[!] [#{pool}] _check_pool failed with an error while evaluating discovered VMs: MockError")

        subject._check_pool(pool_object,provider)
      end

      ['pending','ready','running','completed'].each do |queue_name|
        context "exists in the #{queue_name} queue" do
          before(:each) do
            allow(subject).to receive(:migrate_vm)
            allow(subject).to receive(:check_running_vm)
            allow(subject).to receive(:check_ready_vm)
            allow(subject).to receive(:check_pending_vm)
            allow(subject).to receive(:destroy_vm)
            allow(subject).to receive(:clone_vm)
          end

          it "should remain in the #{queue_name} queue" do
            redis.sadd("vmpooler__#{queue_name}__#{pool}", vm)
            allow(logger).to receive(:log)

            subject._check_pool(pool_object,provider)

            expect(redis.sismember("vmpooler__#{queue_name}__#{pool}", vm)).to be(true)
          end

          it "should be removed from the discovered queue" do
            redis.sadd("vmpooler__#{queue_name}__#{pool}", vm)
            allow(logger).to receive(:log)

            expect(redis.sismember("vmpooler__discovered__#{pool}", vm)).to be(true)
            subject._check_pool(pool_object,provider)
            expect(redis.sismember("vmpooler__discovered__#{pool}", vm)).to be(false)
          end

          it "should log a message" do
            redis.sadd("vmpooler__#{queue_name}__#{pool}", vm)
            expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' found in '#{queue_name}', removed from 'discovered' queue")

            subject._check_pool(pool_object,provider)
          end
        end
      end
    end

    # MIGRATIONS
    context 'Migrating VM not in the inventory' do
      before(:each) do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return(new_vm_response)
        expect(logger).to receive(:log).with('s', "[?] [#{pool}] '#{new_vm}' added to 'discovered' queue")
        create_migrating_vm(vm,pool)
      end

      it 'should not do anything' do
        expect(subject).to receive(:migrate_vm).exactly(0).times

        subject._check_pool(pool_object,provider)
      end
    end

    context 'Migrating VM in the inventory' do
      before(:each) do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return(vm_response)
        allow(subject).to receive(:check_ready_vm)
        allow(logger).to receive(:log).with("s", "[!] [#{pool}] is empty")
        create_migrating_vm(vm,pool)
      end

      it 'should return the number of migrated VMs' do
        allow(subject).to receive(:migrate_vm).with(vm,pool,provider)
        result = subject._check_pool(pool_object,provider)

        expect(result[:migrated_vms]).to be(1)
      end

      it 'should log an error if one occurs' do
        expect(subject).to receive(:migrate_vm).and_raise(RuntimeError,'MockError')
        expect(logger).to receive(:log).with('s', "[x] [#{pool}] '#{vm}' failed to migrate: MockError")

        subject._check_pool(pool_object,provider)
      end

      it 'should call migrate_vm' do
        expect(subject).to receive(:migrate_vm).with(vm,pool,provider)

        subject._check_pool(pool_object,provider)
      end
    end

    # REPOPULATE
    context 'Repopulate a pool' do
    let(:config) {
      YAML.load(<<-EOT
---
:config:
  task_limit: 10
:pools:
  - name: #{pool}
    size: 0
EOT
      )
    }
      it 'should not call clone_vm when number of VMs is equal to the pool size' do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return([])
        expect(subject).to receive(:clone_vm).exactly(0).times

        subject._check_pool(pool_object,provider)
      end

      it 'should not call clone_vm when number of VMs is greater than the pool size' do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return(vm_response)
        create_ready_vm(pool,vm,token)
        expect(subject).to receive(:clone_vm).exactly(0).times

        subject._check_pool(pool_object,provider)
      end

      ['ready','pending'].each do |queue_name|
        it "should use VMs in #{queue_name} queue to caculate pool size" do
          expect(provider).to receive(:vms_in_pool).with(pool).and_return(vm_response)
          expect(subject).to receive(:clone_vm).exactly(0).times
          # Modify the pool size to 1 and add a VM in the queue
          redis.sadd("vmpooler__#{queue_name}__#{pool}",vm)
          config[:pools][0]['size'] = 1
          
          subject._check_pool(pool_object,provider)
        end
      end

      ['running','completed','discovered','migrating'].each do |queue_name|
        it "should not use VMs in #{queue_name} queue to caculate pool size" do
          expect(provider).to receive(:vms_in_pool).with(pool).and_return(vm_response)
          expect(subject).to receive(:clone_vm)
          # Modify the pool size to 1 and add a VM in the queue
          redis.sadd("vmpooler__#{queue_name}__#{pool}",vm)
          config[:pools][0]['size'] = 1

          subject._check_pool(pool_object,provider)
        end
      end

      it 'should log a message the first time a pool is empty' do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return([])
        expect(logger).to receive(:log).with('s', "[!] [#{pool}] is empty")

        subject._check_pool(pool_object,provider)
      end

      context 'when pool is marked as empty' do
        let(:vm_response) {
          # Mock response from Base Provider for vms_in_pool
          [{ 'name' => vm}]
        }          

        before(:each) do
          redis.set("vmpooler__empty__#{pool}", 'true')
        end

        it 'should not log a message when the pool remains empty' do
          expect(provider).to receive(:vms_in_pool).with(pool).and_return([])
          expect(logger).to receive(:log).with('s', "[!] [#{pool}] is empty").exactly(0).times

          subject._check_pool(pool_object,provider)
        end

        it 'should remove the empty pool mark if it is no longer empty' do
          expect(provider).to receive(:vms_in_pool).with(pool).and_return(vm_response)
          create_ready_vm(pool,vm,token)

          expect(redis.get("vmpooler__empty__#{pool}")).to be_truthy
          subject._check_pool(pool_object,provider)
          expect(redis.get("vmpooler__empty__#{pool}")).to be_falsey
        end
      end

      context 'when number of VMs is less than the pool size' do
        before(:each) do
          expect(provider).to receive(:vms_in_pool).with(pool).and_return([])
        end

        it 'should return the number of cloned VMs' do
          pool_size = 5
          config[:pools][0]['size'] = pool_size

          result = subject._check_pool(pool_object,provider)

          expect(result[:cloned_vms]).to be(pool_size)
        end

        it 'should call clone_vm to populate the pool' do
          pool_size = 5
          config[:pools][0]['size'] = pool_size

          expect(subject).to receive(:clone_vm).exactly(pool_size).times
          
          subject._check_pool(pool_object,provider)
        end

        it 'should call clone_vm until task_limit is hit' do
          task_limit = 2
          pool_size = 5
          config[:pools][0]['size'] = pool_size
          config[:config]['task_limit'] = task_limit

          expect(subject).to receive(:clone_vm).exactly(task_limit).times
          
          subject._check_pool(pool_object,provider)
        end

        it 'log a message if a cloning error occurs' do
          pool_size = 1
          config[:pools][0]['size'] = pool_size

          expect(subject).to receive(:clone_vm).and_raise(RuntimeError,"MockError")
          expect(logger).to receive(:log).with("s", "[!] [#{pool}] clone failed during check_pool with an error: MockError")
          expect(logger).to receive(:log).with('d', "[!] [#{pool}] _check_pool failed with an error: MockError")
          
          expect{ subject._check_pool(pool_object,provider) }.to raise_error(RuntimeError,'MockError')
        end
      end

      context 'export metrics' do
        it 'increments metrics for ready queue' do
          create_ready_vm(pool,'vm1')
          create_ready_vm(pool,'vm2')
          create_ready_vm(pool,'vm3')
          expect(provider).to receive(:vms_in_pool).with(pool).and_return(multi_vm_response)

          expect(metrics).to receive(:gauge).with("ready.#{pool}", 3)
          allow(metrics).to receive(:gauge)

          subject._check_pool(pool_object,provider)
        end

        it 'increments metrics for running queue' do
          create_running_vm(pool,'vm1',token)
          create_running_vm(pool,'vm2',token)
          create_running_vm(pool,'vm3',token)
          expect(provider).to receive(:vms_in_pool).with(pool).and_return(multi_vm_response)

          expect(metrics).to receive(:gauge).with("running.#{pool}", 3)
          allow(metrics).to receive(:gauge)

          subject._check_pool(pool_object,provider)
        end

        it 'increments metrics with 0 when pool empty' do
        expect(provider).to receive(:vms_in_pool).with(pool).and_return([])

          expect(metrics).to receive(:gauge).with("ready.#{pool}", 0)
          expect(metrics).to receive(:gauge).with("running.#{pool}", 0)

          subject._check_pool(pool_object,provider)
        end
      end
    end
  end
end
