function xdot = rocket_dynamics(t,x,d,x_R1,x_R2,x_R3,x_R4,I,Fpitch_loop,Fyaw_loop,Mroll_loop,psi_ref,theta_ref,wx_ref,total_time,...
                                mu_psi,mu_theta,mu_phi,mu_psidot,mu_thetadot,mu_phidot,Cov_psi_cholesky,Cov_theta_cholesky,Cov_phi_cholesky)
    % This function is the dynamical system of the actively controlled Falco-4 rocket
    
    global CONTROL__TIME_STEP;
    global CONTROL__START_TIME;
    global VALVE__MAX_THRUST;
    global VALVE__SLEW_RATE;
    global TIME_RCS_WORKED;
    
    global Fyaw;
    global Fpitch;
    global Mroll;
    
    global R1; global R2; global R3; global R4;
    
    global t_last;
    
    global data_log;
        
    global P_psi; global P_psidot; global P_theta; global P_thetadot; global P_phi; global P_phidot; % Load estimate covariance matrices
    global x_psi; global x_psidot; global x_theta; global x_thetadot; global x_phi; global x_phidot; % Load state estimate matrices
    global Q_psi; global Q_psidot; global Q_theta; global Q_thetadot; global Q_phi; global Q_phidot; % Load process noise covariance matrices
    global R_psi; global R_psidot; global R_theta; global R_thetadot; global R_phi; global R_phidot; % Load measurement noise covariance matrices
       
    %*** Ideal world rocket orientation
    psi=x(1);
    wz=x(2);
    theta=x(3);
    wy=x(4);
    phi=x(5);
    wx=x(6);
    w=[wx;wy;wz];
    
    psidot = sin(phi)/cos(theta)*wy+cos(phi)/cos(theta)*wz;
    thetadot = cos(phi)*wy-sin(phi)*wz;
    phidot = wx+tan(theta)*(sin(phi)*wy+cos(phi)*wz);
    
    %*** Introduce disturbances (to see control response)
    % YOU MAY EDIT THESE TO APPLY DIFFERENT DISTURBANCES
%     if (t>=5 && t<=5.1)
%         psidot=psidot+d2r(40)*heaviside(t-5);
%         phidot=phidot+d2r(100)*heaviside(t-5);
%     end

    dt=t-t_last; % Time change
    if (dt>=CONTROL__TIME_STEP)
        %*** Simulate raw signals (affected by noise)
        noise_on_psi=[mu_psi mu_psidot]+randn(1,2)*Cov_psi_cholesky; % Bivariate normal distribution of noise for the (psi,psidot) signal
        noise_on_theta=[mu_theta mu_thetadot]+randn(1,2)*Cov_theta_cholesky; % Bivariate normal distribution of noise for the (theta,thetadot) signal
        noise_on_phi=[mu_phi mu_phidot]+randn(1,2)*Cov_phi_cholesky; % Bivariate normal distribution of noise for the (phi,phidot) signal

        psi_imu=psi+noise_on_psi(1);
        psidot_imu=psidot+noise_on_psi(2);
        theta_imu=theta+noise_on_theta(1);
        thetadot_imu=thetadot+noise_on_theta(2);
        phi_imu=phi+noise_on_phi(1);
        phidot_imu=phidot+noise_on_phi(2);
        
        %*** Now filter these noisy signals with Kalman filtering to obtain smoothed signals used for control
        % Filter the IMU angles and the very noisy numerical derivatives
        [x_psi,P_psi] = kalmanFnc(x_psi,P_psi,psi_imu,Q_psi,R_psi,dt);
        [x_psidot,P_psidot] = kalmanFnc(x_psidot,P_psidot,psidot_imu,Q_psidot,R_psidot,dt);
        [x_theta,P_theta] = kalmanFnc(x_theta,P_theta,theta_imu,Q_theta,R_theta,dt);
        [x_thetadot,P_thetadot] = kalmanFnc(x_thetadot,P_thetadot,thetadot_imu,Q_thetadot,R_thetadot,dt);
        [x_phi,P_phi] = kalmanFnc(x_phi,P_phi,phi_imu,Q_phi,R_phi,dt);
        [x_phidot,P_phidot] = kalmanFnc(x_phidot,P_phidot,phidot_imu,Q_phidot,R_phidot,dt);
        
        % Recuperate the filtered signals
        psi_filt=x_psi(1);
        psidot_filt=x_psidot(1);
        theta_filt=x_theta(1);
        thetadot_filt=x_thetadot(1);
        phi_filt=x_phi(1);
        phidot_filt=x_phidot(1);
        
        % Find the body rates from the filtered signals
        wx_filt=phidot_filt-psidot_filt*sin(theta_filt);
		wy_filt=thetadot_filt*cos(phi_filt)+psidot_filt*cos(theta_filt)*sin(phi_filt);
		wz_filt=psidot_filt*cos(theta_filt)*cos(phi_filt)-thetadot_filt*sin(phi_filt);
        
        %*** Now that filtered signals are available, we must apply a control law
        if (t>=CONTROL__START_TIME) % Apply control once contorl time starts
            % NB : here we only UPDATE the control forces... these are always applies to the rocket
            % in the simulation, but we only just update "what" is being applied at the control
            % frequency!
            %******************************* Fpitch *******************************
            Fpitch = Fpitch_loop.K*(theta_filt-theta_ref)+Fpitch_loop.Td*thetadot_filt;
            %******************************* Fyaw *********************************
            Fyaw = Fyaw_loop.K*(psi_filt-psi_ref)+Fyaw_loop.Td*psidot_filt;
            %******************************* Mroll ********************************
            Mroll = Mroll_loop.K*(wx_filt-wx_ref);
            %**********************************************************************

            %*** Simplex optimal thrust allocation
            % Here we allocate optimally thrust amongst the 4 RCS valves such that we obtain Fpitch, Fyaw and Mroll
            % (unless saturations occur)
            f = [1;1;1;1];
            Aeq = [cos(phi_filt)    -sin(phi_filt)    -cos(phi_filt)    sin(phi_filt)
                   sin(phi_filt)    cos(phi_filt)     -sin(phi_filt)    -cos(phi_filt)
                   d           -d           d          -d];
            beq = [Fpitch;Fyaw;Mroll];
            lb = [0;0;0;0];

            options = optimoptions('linprog','Display','off');
            [X,~,exitflag] = linprog(f,[],[],Aeq,beq,lb,[],[],options);

            if exitflag~=1
                warning('linprog did not converge!'); % Print an error in case optimization went haywire!
            end

            % Assign the valve thrusts
            % Apply saturation and slew rate actuator limits
            TIME_RCS_WORKED=TIME_RCS_WORKED+dt;
            X(1)=limit_actuator(X(1),abs(R1(3)),dt,VALVE__MAX_THRUST,VALVE__SLEW_RATE);
            X(2)=limit_actuator(X(2),abs(R2(2)),dt,VALVE__MAX_THRUST,VALVE__SLEW_RATE);
            X(3)=limit_actuator(X(3),abs(R3(3)),dt,VALVE__MAX_THRUST,VALVE__SLEW_RATE);
            X(4)=limit_actuator(X(4),abs(R4(2)),dt,VALVE__MAX_THRUST,VALVE__SLEW_RATE);          
            
            % Assign valve thrusts to force vectors that their thrusts generate
            R1=[0;0;X(1)];
            R2=[0;-X(2);0];
            R3=[0;0;-X(3)];
            R4=[0;X(4);0];
        
            fprintf('Time: %.4f \t (out of %.1f [s])\n',t,total_time);
            data_log = [data_log;
                        t dt psi_imu theta_imu phi_imu psidot_imu thetadot_imu phidot_imu psi_filt theta_filt phi_filt psidot_filt thetadot_filt phidot_filt...
                        wx_filt wy_filt wz_filt Fpitch Fyaw Mroll X(1) X(2) X(3) X(4)];
        end
        t_last=t; % Memorize the time that we were in this if statement
    end
    
    %*** Rocket dynamics
    % We simulate the rocket dynamics here    
    % Simulate a perturbing moment acting at the rocket center of mass (these may be aerodynamic forces from wind gusts, of instance)
    % NB : This moment is applied to the BODY AXES (attached to and rotate with the rocket!). Axes used : Tait-Bryan, see
    %      (http://en.wikipedia.org/wiki/Euler_angles#Tait.E2.80.93Bryan_angles). You may yourself however project a moment from the world axes (fixed) onto
    %      the body axes using the rotation matrix world-->body (using Tait-Bryan angle convention).
    % YOU MAY EDIT THIS TO APPLY DIFFERENT PERTURBING MOMENT (you could even add an accurate aerodynamic model and add it to Mtot)
    Mperturb=[0;0;0];
%     if (t>=3 && t<=3.1)
%         Mperturb = [0;0.3;0.3];
%     end
    
    Mtot = cross(x_R1,R1)+cross(x_R2,R2)+cross(x_R3,R3)+cross(x_R4,R4)+Mperturb; % Moment acting on rocket, assumed to be just the RCS (aerodynamic forces neglected
                                                                                 % as RCS control only makes sense at relatively low speeds)
    wdot = I\(Mtot-cross(w,I*w)); % Euler's rigid body dynamics equation
    
    wxdot = wdot(1);
    wydot = wdot(2);
    wzdot = wdot(3);
    
    % Finally, assign the state derivatives
    xdot = [psidot;wzdot;thetadot;wydot;phidot;wxdot];
end

function y = limit_actuator(x,x_prev,dt,saturation,slew_rate)
    
    global TIME__DROPOFF;
    global TIME__FULL;
    global DROPOFF_CONSTANT;
    global TIME_RCS_WORKED;
    
    if (TIME_RCS_WORKED>TIME__DROPOFF && TIME_RCS_WORKED<TIME__FULL)
        saturation=saturation*exp(-(TIME_RCS_WORKED-TIME__DROPOFF)/DROPOFF_CONSTANT);
    elseif (TIME_RCS_WORKED>=TIME__FULL)
        saturation=0;
    end

    SR_up=0; % ==1 when control increasing faster than slew rate on going up
    SR_down=0; % ==1 when control decreasing faster than slew rate on going down
    
    y=x; % By default, let the limited control value be the original control value (assume no limits have been violated)
    if (x>=(x_prev+slew_rate*dt))
        SR_up=1;
    end
    if (x<=(x_prev-slew_rate*dt))
        SR_down=1;
    end
    
    if (SR_up) % Slew rate limit on going up. giving that we haven't saturated already
        y=x_prev+slew_rate*dt;
    end
    if (y>=saturation) % Saturation
        y=saturation;
    end
    if (SR_down) % Slew rate limit on coming down
        y=x_prev-slew_rate*dt;
    end
end
