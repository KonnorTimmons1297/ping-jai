#import "Basic";
#import "String";
#import "Socket";
#import "POSIX";

main :: () {
	address_to_ping: string;
	packet_count := 5;
	
	args := get_command_line_arguments();
	
	if args.count < 2 {
		log("Usage: ping [-packets=<NUMBER>] <ADDRESS>");
		return;
	}
	
	packets_arg := "-packets";
	for arg: args {
		if it_index == 0 continue;
		if begins_with(arg, packets_arg) {
			advance(*arg, packets_arg.count + 1);
			integer_value, parsed_successfully, remainder_of_string := string_to_int(arg);
			if !parsed_successfully {
				log_error("ERROR: Encountered -packets arg but failed to parse integer value");
				continue;
			}
			packet_count = integer_value;
		} else {
			address_to_ping = arg;
		}
	}

	if address_to_ping.count == 0 {
		log_error("Expected address to ping");
		return;
	}

	if !socket_init() {
		log_error("Failed to initialize sockets! OS_Error=%", get_last_socket_error());
		return;
	}

	opened_socket, sock := open_socket_to_address(address_to_ping, true);
	if opened_socket {
		log("Pinging address \"%\", % times", address_to_ping, packet_count);
		success, avg_ping := ping(sock, ping_count = packet_count, timeout = seconds_to_apollo(1));
		if success {
			log("avg_ping=%", avg_ping);
		}
	}
}

// NOTE: must call socket_init() before calling this function 
open_socket_to_address :: (address: string, debug := false) -> (success: bool, sock: Socket) {
	host_data := gethostbyname(address.data);
	
	resolved_address: string;

	for index: 0..host_data.h_length-1 {
		address_type := host_data.h_addrtype;
		if address_type != AF_INET continue;

		h_addr := host_data.h_addr_list[index];
		if !h_addr break;

		test_in_addr: in_addr;
		test_in_addr.s_addr = << cast(*u32) h_addr;

		address_data := inet_ntoa(test_in_addr);
		address_length := 0;
		while address_data[address_length] {
			address_length += 1;
		}

		// Selecting the first address...

		resolved_address.data = address_data;
		resolved_address.count = address_length;
		break;
	}

	if resolved_address.count == 0 {
		log_error("Failed to resolve address for %", address);
		return false, 0;
	}

	if debug log("% => %", address, resolved_address);

	ping_socket := socket(AF_INET, .DGRAM, .ICMP);
	if ping_socket == INVALID_SOCKET {
		log_error("Failed to create client socket. Error=%", get_last_socket_error());
		return false, INVALID_SOCKET;
	}
	
	internet_socket_address_struct: sockaddr_in;
	internet_socket_address_struct.sin_family = AF_INET;
	
	c_address := to_c_string(resolved_address);
	defer free(c_address);
	addr := inet_addr(c_address);
	#if OS == .WINDOWS {
		internet_socket_address_struct.sin_addr.S_un.S_addr = addr;
	} else {
		internet_socket_address_struct.sin_addr.s_addr = addr;
	}

	server_address := internet_socket_address_struct;
	if connect(ping_socket, cast(*sockaddr) *server_address, size_of(type_of(server_address))) != 0 {
		log_error("Failed to connect. OS_Error=%", get_last_socket_error());
		close_and_reset(*ping_socket);
		return false, INVALID_SOCKET;
	}
	
	return true, ping_socket;
}

ping :: (ping_socket: Socket, ping_count: int, timeout: Apollo_Time, verbose := false) -> (success: bool, avg_ms: float) {
	ICMP_Type :: enum u8 {
		ECHO_REPLY :: 0;
		DESTINATION_UNREACHABLE :: 3;
		REDIRECT_MESSAGE :: 5;
		ECHO_REQUEST :: 8;
	};
	
	ICMP_Packet :: struct {
		type: ICMP_Type;
		code: u8;
		checksum: u16;
		id: u16;
		sequence_number: u16;
	};


	successful_pings := 0;
	ping_round_trip_sum_ms: float = 0.0;

	for iteration: 0..ping_count-1 {
		{
			echo_request: ICMP_Packet;
			echo_request.type = .ECHO_REQUEST;
			echo_request.sequence_number = htons(xx iteration);

			send_result := send(ping_socket, cast(*u8) *echo_request, size_of(ICMP_Packet), 0);
			if send_result != size_of(ICMP_Packet) {
				return false, 0;
			}
		}

		start_time := current_time_monotonic();

		select_fdset: fd_set;
		FD_SET(ping_socket, *select_fdset);

		select_timeout: timeval;
		select_timeout.tv_usec = to_microseconds(timeout);

		select_result := select(ping_socket+1, *select_fdset, null, null, *select_timeout);

		timed_out := select_result == 0;
		if timed_out {
			continue;
		}

		// there is data ready to read, so read it.
		response_buffer: [size_of(ICMP_Packet)] u8;
		recv_result := recv(ping_socket, cast(*u8) *response_buffer, size_of(ICMP_Packet), 0);
		if recv_result {
			end_time := current_time_monotonic();
			elapsed_time := to_milliseconds(end_time - start_time);
			ping_round_trip_sum_ms += elapsed_time;
			successful_pings += 1;

			received_packet := << cast(*ICMP_Packet) *response_buffer;
		}
	}

	return true, (ping_round_trip_sum_ms / successful_pings);
}
